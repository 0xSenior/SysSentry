#!/usr/bin/env bash
#
# lib/process.sh — SysSentry Process Governor Module
#
# Scans /proc for rogue processes exceeding memory/CPU bounds and enforces a
# graceful termination cascade: SIGTERM (15) -> non-blocking grace-wait ->
# SIGKILL (9) only on refusal.
#
# Absolute PID protection (O(1) whitelist) prevents termination of PID 1,
# kernel daemons, the script itself ($$), its parent ($PPID), and
# user-configured PIDs. All scanning is O(N) single-pass over /proc.
#
# Namespace: Process:: (public), Process::_* (private)

# shellcheck disable=SC2154,SC2034
set -euo pipefail

declare -a Process_ROGUE_PIDS=()
declare -A Process_ROGUE_DETAILS=()

###############################################################################
# Process::is_protected_pid
#
# Returns true (0) if the PID is in the O(1) protection whitelist and must
# never be terminated.
#
# @param pid process identifier
# @return Core_EXIT_SUCCESS if protected, Core_ERR_GENERAL otherwise
###############################################################################
Process::is_protected_pid() {
    local -r _pid="${1:-0}"
    [[ -v "Core_PROTECTED_PIDS[${_pid}]" ]]
}

###############################################################################
# Process::_parse_stat_line
#
# Parses a /proc/<pid>/stat line into the ProcessRecord entity. The comm field
# (field 2) is wrapped in parentheses and may contain spaces, so it is
# extracted between the first '(' and last ')'. Remaining fields are sliced
# positionally after the closing ')'.
#
# /proc/<pid>/stat layout after comm:
#   state(3) ppid(4) ... utime(14) stime(15) ... vsize(23) rss(24)
#
# @param pid process identifier
# @param stat_line raw /proc/<pid>/stat content
# @return Core_EXIT_SUCCESS on parse, Core_ERR_GENERAL on failure
###############################################################################
Process::_parse_stat_line() {
    local -r _pid="${1}"
    local -r _stat_line="${2}"

    local _comm _rest _state _ppid _utime _stime _vsize _rss

    _comm="${_stat_line#*(}"
    _comm="${_comm%%)*}"

    _rest="${_stat_line#*) }"
    _state="${_rest%% *}"

    # shellcheck disable=SC2086
    read -r _ _ppid _ _ _ _ _ _ _ _ _ _ _utime _stime _ _ _ _vsize _rss _ <<< "${_rest}"

    ProcessRecord::set pid "${_pid}"
    ProcessRecord::set ppid "${_ppid:-0}"
    ProcessRecord::set name "${_comm}"
    ProcessRecord::set state "${_state}"
    ProcessRecord::set utime "${_utime:-0}"
    ProcessRecord::set stime "${_stime:-0}"
    ProcessRecord::set vsize "${_vsize:-0}"
    ProcessRecord::set rss "${_rss:-0}"

    return "${Core_EXIT_SUCCESS}"
}

###############################################################################
# Process::_get_system_cpu_total
#
# Returns aggregate CPU jiffies from the first "cpu " line of /proc/stat.
#
# @return total jiffies on stdout
###############################################################################
Process::_get_system_cpu_total() {
    local _label _u _n _s _i _w _irq _sirq _st _rest
    local -i _total=0

    while IFS=' ' read -r _label _u _n _s _i _w _irq _sirq _st _rest; do
        [[ "${_label}" == "cpu" ]] || continue
        _total=$(( _u + _n + _s + _i + _w + _irq + _sirq + _st ))
        break
    done < /proc/stat

    echo "${_total}"
}

###############################################################################
# Process::_get_mem_total_kb
#
# Returns system RAM total in kB from /proc/meminfo.
#
# @return memory total in kB on stdout
###############################################################################
Process::_get_mem_total_kb() {
    local _k _v

    while IFS=: read -r _k _v || [[ -n "${_k}" ]]; do
        _k="${_k// /}"
        _v="${_v// /}"
        _v="${_v%%kB*}"
        if [[ "${_k}" == "MemTotal" ]]; then
            echo "${_v}"
            return 0
        fi
    done < /proc/meminfo

    echo "0"
}

###############################################################################
# Process::_compute_cpu_percent
#
# Computes delta-based CPU utilisation percentage (fixed-point x10) for a PID
# from two utime/stime samples and two system-total samples. Inlined in the
# scan loop to avoid a subshell fork per process.
#
# @param utime_new current utime jiffies
# @param stime_new current stime jiffies
# @param utime_old previous utime jiffies
# @param stime_old previous stime jiffies
# @param total_new current system total jiffies
# @param total_old previous system total jiffies
# @return fixed-point x10 percentage on stdout
###############################################################################
Process::_compute_cpu_percent() {
    local -r _utime_new="${1}"
    local -r _stime_new="${2}"
    local -r _utime_old="${3}"
    local -r _stime_old="${4}"
    local -r _total_new="${5}"
    local -r _total_old="${6}"

    local -i _proc_delta _total_delta _pct=0

    _proc_delta=$(( (_utime_new + _stime_new) - (_utime_old + _stime_old) ))
    _total_delta=$(( _total_new - _total_old ))

    if [[ ${_total_delta} -gt 0 && ${_proc_delta} -gt 0 ]]; then
        _pct=$(( (_proc_delta * 1000) / _total_delta ))
    fi

    echo "$(( _pct / 10 )).$(( _pct % 10 ))"
}

###############################################################################
# Process::scan_rogue
#
# O(N) single-pass scan of /proc for rogue processes. For each numeric PID
# directory: skips protected PIDs (O(1)), reads /proc/<pid>/stat twice across
# a bounded interval, computes memory and CPU utilisation, and flags processes
# exceeding thresholds.
#
# Results are stored in Process_ROGUE_PIDS / Process_ROGUE_DETAILS.
#
# @param warn_mem memory % threshold (default from config)
# @param warn_cpu cpu % threshold (default from config)
# @return Core_EXIT_SUCCESS
###############################################################################
Process::scan_rogue() {
    local -r _warn_mem="${1:-${Core_CONFIG[warn_mem_percent_proc]:-10}}"
    local -r _warn_cpu="${2:-${Core_CONFIG[warn_cpu_percent_proc]:-10}}"

    local _mem_total_kb _pid_dir _pid _rss_kb _mem_pct_int
    local _cpu_pct _cpu_pct_int _name _state _total_before _total_after
    local -i _ut1 _st1 _ut2 _st2

    Process_ROGUE_PIDS=()
    Process_ROGUE_DETAILS=()

    _mem_total_kb="$(Process::_get_mem_total_kb)"
    if [[ ${_mem_total_kb} -le 0 ]]; then
        _mem_total_kb=1
    fi

    _total_before="$(Process::_get_system_cpu_total)"
    Core::msleep 0.3
    _total_after="$(Process::_get_system_cpu_total)"

    local _line _rest _comm _state2 _ppid2 _utime2 _stime2 _vsize2 _rss2

    for _pid_dir in /proc/[0-9]*; do
        _pid="${_pid_dir##*/}"

        if Process::is_protected_pid "${_pid}"; then
            continue
        fi

        if [[ ! -r "/proc/${_pid}/stat" ]]; then
            continue
        fi

        IFS= read -r _line < "/proc/${_pid}/stat" 2>/dev/null || continue
        Process::_parse_stat_line "${_pid}" "${_line}"

        _rss_kb="${Core_PROCESS_RECORD[rss]}"
        _name="${Core_PROCESS_RECORD[name]}"
        _state="${Core_PROCESS_RECORD[state]}"
        _ut1="${Core_PROCESS_RECORD[utime]}"
        _st1="${Core_PROCESS_RECORD[stime]}"

        IFS= read -r _line < "/proc/${_pid}/stat" 2>/dev/null || continue
        _comm="${_line#*(}"; _comm="${_comm%%)*}"
        _rest="${_line#*) }"
        _state2="${_rest%% *}"
        # shellcheck disable=SC2086
        read -r _ _ppid2 _ _ _ _ _ _ _ _ _ _ _utime2 _stime2 _ _ _ _vsize2 _rss2 _ <<< "${_rest}"

        _mem_pct_int=0
        if [[ ${_mem_total_kb} -gt 0 && -n "${_rss2}" && ${_rss2} -gt 0 ]]; then
            _mem_pct_int=$(( (_rss2 * 1000) / _mem_total_kb ))
        fi

        _cpu_pct="$(Process::_compute_cpu_percent "${_utime2}" "${_stime2}" "${_ut1}" "${_st1}" "${_total_after}" "${_total_before}")"
        _cpu_pct_int="${_cpu_pct%.*}"
        [[ -z "${_cpu_pct_int}" ]] && _cpu_pct_int=0

        if [[ ${_mem_pct_int} -ge ${_warn_mem} ]] || [[ ${_cpu_pct_int} -ge ${_warn_cpu} ]]; then
            Process_ROGUE_PIDS+=("${_pid}")
            Process_ROGUE_DETAILS[${_pid}]="name=${_name} state=${_state2} rss_kb=${_rss2} mem_pct=${_mem_pct_int} cpu_pct=${_cpu_pct_int}"

            ProcessRecord::set pid "${_pid}"
            ProcessRecord::set ppid "${_ppid2:-0}"
            ProcessRecord::set name "${_name}"
            ProcessRecord::set state "${_state2}"
            ProcessRecord::set mem_rss_kb "${_rss2}"
            ProcessRecord::set mem_percent "$(( _mem_pct_int / 10 )).$(( _mem_pct_int % 10 ))"
            ProcessRecord::set cpu_percent "${_cpu_pct}"
            ProcessRecord::set rogue "true"
            ProcessRecord::set action_taken "none"
        fi
    done

    Core::log DEBUG "Rogue scan complete: ${#Process_ROGUE_PIDS[@]} rogue(s) found (mem>=${_warn_mem}%, cpu>=${_warn_cpu}%)"

    return "${Core_EXIT_SUCCESS}"
}

###############################################################################
# Process::list_rogues
#
# Prints detected rogue processes to stdout in a formatted table.
#
# @return Core_EXIT_SUCCESS
###############################################################################
Process::list_rogues() {
    local _pid

    if [[ ${#Process_ROGUE_PIDS[@]} -eq 0 ]]; then
        Core::log INFO "No rogue processes detected"
        return "${Core_EXIT_SUCCESS}"
    fi

    printf '%bRogue processes detected (%d):%b\n' "${Core_C_YELLOW}" "${#Process_ROGUE_PIDS[@]}" "${Core_C_RESET}"
    printf '  %-8s %-20s %-10s %-10s %-10s %-10s\n' "PID" "NAME" "STATE" "MEM%" "CPU%" "RSS(KB)"
    printf '  %-8s %-20s %-10s %-10s %-10s %-10s\n' "---" "----" "-----" "----" "---" "-------"

    for _pid in "${Process_ROGUE_PIDS[@]}"; do
        printf '  %-8s %-20s %-10s %-10s %-10s %-10s\n' \
            "${_pid}" "${Core_PROCESS_RECORD[name]:-}" "${Core_PROCESS_RECORD[state]:-}" \
            "${Core_PROCESS_RECORD[mem_percent]:-}" "${Core_PROCESS_RECORD[cpu_percent]:-}" \
            "${Core_PROCESS_RECORD[mem_rss_kb]:-}"
    done
    printf '\n'

    return "${Core_EXIT_SUCCESS}"
}

###############################################################################
# Process::terminate_cascade
#
# Enforces a graceful termination cascade:
#   1. SIGTERM (15)
#   2. Non-blocking grace-wait loop (poll kill -0 every 0.2s)
#   3. SIGKILL (9) escalation only if the process refuses to terminate
#
# @param pid  process identifier to terminate
# @param grace grace period in seconds (default: 5)
# @param name process name for logging
# @return Core_EXIT_SUCCESS on graceful termination,
#         1 if escalated to SIGKILL,
#         Core_ERR_PROCESS on failure or protected PID
###############################################################################
Process::terminate_cascade() {
    local -r _pid="${1}"
    local -r _grace="${2:-5}"
    local -r _name="${3:-unknown}"
    local -i _elapsed_tenths=0

    if Process::is_protected_pid "${_pid}"; then
        Core::log WARN "Refusing to terminate protected PID ${_pid} (${_name})"
        ProcessRecord::set action_taken "protected"
        return "${Core_ERR_PROCESS}"
    fi

    if ! kill -0 "${_pid}" 2>/dev/null; then
        Core::log INFO "PID ${_pid} (${_name}) already terminated"
        ProcessRecord::set action_taken "already-dead"
        return "${Core_EXIT_SUCCESS}"
    fi

    Core::log INFO "Sending SIGTERM to PID ${_pid} (${_name})"
    if ! kill -TERM "${_pid}" 2>/dev/null; then
        Core::log WARN "SIGTERM failed for PID ${_pid} (${_name})"
        ProcessRecord::set action_taken "sigterm-failed"
        return "${Core_ERR_PROCESS}"
    fi

    Core::log INFO "Grace period ${_grace}s for PID ${_pid} (${_name})"

    # Grace-wait: poll every 0.2s. _elapsed_tenths counts 0.2s ticks, so
    # grace seconds * 5 = total ticks. E.g. grace=5 => 25 ticks => 5s actual.
    while [[ ${_elapsed_tenths} -lt $(( _grace * 5 )) ]]; do
        if ! kill -0 "${_pid}" 2>/dev/null; then
            Core::log INFO "PID ${_pid} (${_name}) terminated gracefully"
            ProcessRecord::set action_taken "sigterm"
            return "${Core_EXIT_SUCCESS}"
        fi
        Core::msleep 0.2
        _elapsed_tenths=$(( _elapsed_tenths + 1 ))
    done

    if kill -0 "${_pid}" 2>/dev/null; then
        Core::log WARN "PID ${_pid} (${_name}) refused SIGTERM; escalating to SIGKILL"
        if kill -KILL "${_pid}" 2>/dev/null; then
            Core::log INFO "SIGKILL sent to PID ${_pid} (${_name})"
            ProcessRecord::set action_taken "sigkill"
            return 1
        else
            Core::log ERROR "SIGKILL failed for PID ${_pid} (${_name})"
            ProcessRecord::set action_taken "sigkill-failed"
            return "${Core_ERR_PROCESS}"
        fi
    fi

    ProcessRecord::set action_taken "sigterm"
    return "${Core_EXIT_SUCCESS}"
}

###############################################################################
# Process::govern
#
# Scans for rogue processes and terminates each via the termination cascade.
# Protected PIDs are skipped without termination.
#
# @param warn_mem memory % threshold
# @param warn_cpu cpu % threshold
# @param grace grace period in seconds
# @return Core_EXIT_SUCCESS on success, Core_ERR_GENERAL if any termination failed
###############################################################################
Process::govern() {
    local -r _warn_mem="${1:-${Core_CONFIG[warn_mem_percent_proc]:-10}}"
    local -r _warn_cpu="${2:-${Core_CONFIG[warn_cpu_percent_proc]:-10}}"
    local -r _grace="${3:-5}"

    local _pid _rc _terminated=0 _killed=0 _skipped=0 _failed=0

    Core::banner "Process Governor"
    Core::log INFO "Starting rogue process governance (mem>=${_warn_mem}%, cpu>=${_warn_cpu}%, grace=${_grace}s)"

    Process::scan_rogue "${_warn_mem}" "${_warn_cpu}"

    if [[ ${#Process_ROGUE_PIDS[@]} -eq 0 ]]; then
        Process::list_rogues
        return "${Core_EXIT_SUCCESS}"
    fi

    Process::list_rogues

    for _pid in "${Process_ROGUE_PIDS[@]}"; do
        ProcessRecord::set pid "${_pid}"
        ProcessRecord::set action_taken "none"

        if Process::is_protected_pid "${_pid}"; then
            Core::log WARN "Skipping protected PID ${_pid}"
            _skipped=$(( _skipped + 1 ))
            continue
        fi

        Process::terminate_cascade "${_pid}" "${_grace}" "${Core_PROCESS_RECORD[name]}"
        _rc=$?

        case ${_rc} in
            0) _terminated=$(( _terminated + 1 )) ;;
            1) _killed=$(( _killed + 1 )) ;;
            *) _failed=$(( _failed + 1 )) ;;
        esac
    done

    printf '\n%bGovernor summary:%b terminated=%d sigkill=%d skipped(protected)=%d failed=%d\n' \
        "${Core_C_BOLD}" "${Core_C_RESET}" \
        "${_terminated}" "${_killed}" "${_skipped}" "${_failed}"

    Core::log INFO "Governor complete (terminated=${_terminated} sigkill=${_killed} skipped=${_skipped} failed=${_failed})"

    if [[ ${_failed} -gt 0 ]]; then
        return "${Core_ERR_GENERAL}"
    fi

    return "${Core_EXIT_SUCCESS}"
}
