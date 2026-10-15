#!/usr/bin/env bash
#
# lib/process.sh — SysSentry Process Governor Module
#
# Scans /proc for rogue processes exceeding memory/CPU bounds and enforces a
# graceful termination cascade:
#   1. SIGTERM (15) — polite request to terminate
#   2. Non-blocking grace-wait loop (poll /proc/<pid>, kill -0)
#   3. SIGKILL (9) — escalation only if the process refuses to die
#
# Absolute PID protection (O(1) whitelist lookups) prevents termination of
#   - PID 1 (init/systemd)
#   - Kernel daemons
#   - The SysSentry script itself ($$) and its parent ($PPID)
#   - User-configured protected PIDs
#
# All scanning is O(N) single-pass over /proc numeric directories.
#
# Namespace: Process::

###############################################################################
# Process::is_protected_pid — O(1) whitelist lookup
#
# Returns 0 (true) if the PID must never be terminated.
###############################################################################
Process::is_protected_pid() {
    local -r _pid="${1:-0}"
    [[ -v "Core_PROTECTED_PIDS[${_pid}]" ]]
}

###############################################################################
# Process::read_stat_fields — read /proc/<pid>/stat into local variables
#
# /proc/<pid>/stat fields (space-separated; comm field may contain spaces/parens):
#   1 pid, 2 comm, 3 state, 4 ppid, ..., 14 utime, 15 stime, ..., 23 vsize, 24 rss
#
# We parse by reading the whole line and extracting fields with awk-like
# slicing in a single pass (no subshell inside the per-PID loop).
###############################################################################
Process::read_stat_fields() {
    local -r _pid="${1}"
    local _stat_file="/proc/${_pid}/stat"
    local _line _fields _utime _stime _vsize _rss _ppid _state _comm _name

    if [[ ! -r "${_stat_file}" ]]; then
        return 1
    fi

    # Read entire stat line in one shot
    IFS= read -r _line < "${_stat_file}" || return 1

    # comm is field 2 and may contain spaces/parentheses: "(comm)"
    # Extract comm between first '(' and last ')'
    _comm="${_line#*(}"
    _comm="${_comm%%)*}"
    _name="${_comm}"

    # Everything after the last ')' is the remaining fields, space-separated.
    # State (field 3) is the first char after ") "
    _rest="${_line#*) }"
    _state="${_rest%% *}"

    # Remaining fields after state: ppid(1), ..., utime(14), stime(15), ... vsize(23), rss(24)
    # After ") state ppid ...", field positions shift:
    #   _rest = "S ppid ... utime stime ... vsize rss ..."
    read -r _ _ppid _ _ _ _ _ _ _ _ _ _ _utime _stime _ _ _ _vsize _rss _ <<< "${_rest}"

    ProcessRecord::set pid "${_pid}"
    ProcessRecord::set ppid "${_ppid:-0}"
    ProcessRecord::set name "${_name}"
    ProcessRecord::set state "${_state}"
    ProcessRecord::set utime "${_utime:-0}"
    ProcessRecord::set stime "${_stime:-0}"
    ProcessRecord::set vsize "${_vsize:-0}"
    ProcessRecord::set rss "${_rss:-0}"

    return 0
}

###############################################################################
# Process::compute_cpu_percent — delta-based CPU utilisation for a PID
#
# Requires two samples of /proc/<pid>/stat and /proc/stat with an interval.
# Returns fixed-point x10 percentage via stdout (no subshell bottleneck).
###############################################################################
Process::compute_cpu_percent() {
    local -r _pid="${1}"
    local -r _utime_new="${2}"
    local -r _stime_new="${3}"
    local -r _utime_old="${4}"
    local -r _stime_old="${5}"
    local -r _total_new="${6}"
    local -r _total_old="${7}"

    local _proc_delta _total_delta _pct=0

    _proc_delta=$(( (_utime_new + _stime_new) - (_utime_old + _stime_old) ))
    _total_delta=$(( _total_new - _total_old ))

    if [[ ${_total_delta} -gt 0 && ${_proc_delta} -gt 0 ]]; then
        _pct=$(( (_proc_delta * 1000) / _total_delta ))
    fi

    # Output fixed-point x10 (e.g. "12.3")
    echo "$(( _pct / 10 )).$(( _pct % 10 ))"
}

###############################################################################
# Process::get_system_cpu_total — aggregate CPU jiffies from /proc/stat
###############################################################################
Process::get_system_cpu_total() {
    local _u _n _s _i _w _irq _sirq _st _total=0
    while IFS=' ' read -r _label _u _n _s _i _w _irq _sirq _st _rest; do
        [[ "${_label}" == "cpu" ]] || continue
        _total=$(( _u + _n + _s + _i + _w + _irq + _sirq + _st ))
        break
    done < /proc/stat
    echo "${_total}"
}

###############################################################################
# Process::get_mem_total_kb — system RAM total from /proc/meminfo
###############################################################################
Process::get_mem_total_kb() {
    local _k _v
    while IFS=: read -r _k _v || [[ -n "${_k}" ]]; do
        _k="${_k// /}"; _v="${_v// /}"; _v="${_v%%kB*}"
        if [[ "${_k}" == "MemTotal" ]]; then
            echo "${_v}"
            return 0
        fi
    done < /proc/meminfo
    echo "0"
}

###############################################################################
# Process::scan_rogue — O(N) single-pass scan of /proc for rogue processes
#
# For each numeric /proc/<pid> directory:
#   1. Skip protected PIDs (O(1) whitelist)
#   2. Read /proc/<pid>/stat for RSS, utime/stime
#   3. Compute memory % and CPU % (delta over a short interval)
#   4. Flag as rogue if exceeding warn thresholds
#
# Results are stored internally; call Process::list_rogues to consume.
###############################################################################
declare -a Process_ROGUE_PIDS=()
declare -A Process_ROGUE_DETAILS=()

Process::scan_rogue() {
    local _warn_mem="${1:-$(Core::config_get warn_mem_percent 10)}"
    local _warn_cpu="${2:-$(Core::config_get warn_cpu_percent 10)}"
    local _mem_total_kb _pid_dir _pid _rss_kb _mem_pct_int
    local _cpu_pct _cpu_pct_int _name _state _total_before _total_after
    local _ut1 _st1 _ut2 _st2

    # Reset rogue accumulators
    Process_ROGUE_PIDS=()
    Process_ROGUE_DETAILS=()

    _mem_total_kb="$(Process::get_mem_total_kb)"
    if [[ ${_mem_total_kb} -le 0 ]]; then
        _mem_total_kb=1   # avoid divide-by-zero
    fi

    # --- First CPU sample ---
    _total_before="$(Process::get_system_cpu_total)"

    # Short interval for CPU delta (non-blocking, bounded)
    Core::msleep 0.3

    # --- Second CPU sample + process scan (single O(N) pass) ---
    _total_after="$(Process::get_system_cpu_total)"

    for _pid_dir in /proc/[0-9]*; do
        # Extract PID from path "/proc/1234" -> "1234"
        _pid="${_pid_dir##*/}"

        # --- O(1) PID protection ---
        if Process::is_protected_pid "${_pid}"; then
            continue
        fi

        # Skip if process vanished mid-scan (TOCTOU-safe)
        if [[ ! -r "/proc/${_pid}/stat" ]]; then
            continue
        fi

        # Read stat fields (single pass)
        if ! Process::read_stat_fields "${_pid}"; then
            continue
        fi

        _rss_kb="${Core_PROCESS_RECORD[rss]}"
        _name="${Core_PROCESS_RECORD[name]}"
        _state="${Core_PROCESS_RECORD[state]}"
        _ut1="${Core_PROCESS_RECORD[utime]}"
        _st1="${Core_PROCESS_RECORD[stime]}"

        # Re-read utime/stime for the second sample (delta)
        # We already read once above; read again from /proc for _ut2/_st2
        local _line2 _rest2 _comm2 _state2 _ppid2 _ut2 _st2 _vsize2 _rss2
        IFS= read -r _line2 < "/proc/${_pid}/stat" 2>/dev/null || continue
        _comm2="${_line2#*(}"; _comm2="${_comm2%%)*}"
        _rest2="${_line2#*) }"
        _state2="${_rest2%% *}"
        read -r _ _ppid2 _ _ _ _ _ _ _ _ _ _ _ut2 _st2 _ _ _ _vsize2 _rss2 _ <<< "${_rest2}"

        # --- Memory % (RSS / MemTotal) ---
        _mem_pct_int=0
        if [[ ${_mem_total_kb} -gt 0 && -n "${_rss2}" && ${_rss2} -gt 0 ]]; then
            _mem_pct_int=$(( (_rss2 * 1000) / _mem_total_kb ))
        fi

        # --- CPU % (delta) ---
        _cpu_pct="$(Process::compute_cpu_percent "${_pid}" "${_ut2}" "${_st2}" "${_ut1}" "${_st1}" "${_total_after}" "${_total_before}")"
        _cpu_pct_int="${_cpu_pct%.*}"
        [[ -z "${_cpu_pct_int}" ]] && _cpu_pct_int=0

        # --- Rogue determination ---
        if [[ ${_mem_pct_int} -ge ${_warn_mem} ]] || [[ ${_cpu_pct_int} -ge ${_warn_cpu} ]]; then
            Process_ROGUE_PIDS+=("${_pid}")
            Process_ROGUE_DETAILS[${_pid}]="name=${_name} state=${_state} rss_kb=${_rss2} mem_pct=${_mem_pct_int} cpu_pct=${_cpu_pct_int}"

            # Update ProcessRecord for the rogue (for reporting)
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
}

###############################################################################
# Process::list_rogues — print rogue PIDs and details
###############################################################################
Process::list_rogues() {
    local _pid _details
    if [[ ${#Process_ROGUE_PIDS[@]} -eq 0 ]]; then
        Core::log INFO "No rogue processes detected"
        return 0
    fi
    printf '%bRogue processes detected (%d):%b\n' "${Core_C_YELLOW}" "${#Process_ROGUE_PIDS[@]}" "${Core_C_RESET}"
    printf '  %-8s %-20s %-10s %-10s %-10s %-10s\n' "PID" "NAME" "STATE" "MEM%" "CPU%" "RSS(KB)"
    printf '  %-8s %-20s %-10s %-10s %-10s %-10s\n' "---" "----" "-----" "----" "---" "-------"
    for _pid in "${Process_ROGUE_PIDS[@]}"; do
        _details="${Process_ROGUE_DETAILS[${_pid}]:-}"
        printf '  %-8s %-20s %-10s %-10s %-10s %-10s\n' \
            "${_pid}" "${Core_PROCESS_RECORD[name]:-}" "${Core_PROCESS_RECORD[state]:-}" \
            "${Core_PROCESS_RECORD[mem_percent]:-}" "${Core_PROCESS_RECORD[cpu_percent]:-}" \
            "${Core_PROCESS_RECORD[mem_rss_kb]:-}"
    done
    printf '\n'
}

###############################################################################
# Process::terminate_cascade — graceful SIGTERM -> grace-wait -> SIGKILL
#
#   1. Send SIGTERM (15)
#   2. Poll kill -0 up to grace_period seconds (non-blocking)
#   3. If still alive, send SIGKILL (9)
#
# Returns 0 if terminated gracefully, 1 if escalated to SIGKILL, 2 on failure.
###############################################################################
Process::terminate_cascade() {
    local -r _pid="${1}"
    local -r _grace="${2:-5}"            # seconds to wait after SIGTERM
    local -r _name="${3:-unknown}"
    local _elapsed=0

    # --- O(1) protection check ---
    if Process::is_protected_pid "${_pid}"; then
        Core::log WARN "Refusing to terminate protected PID ${_pid} (${_name})"
        ProcessRecord::set action_taken "protected"
        return 2
    fi

    # Verify process still exists
    if ! kill -0 "${_pid}" 2>/dev/null; then
        Core::log INFO "PID ${_pid} (${_name}) already terminated"
        ProcessRecord::set action_taken "already-dead"
        return 0
    fi

    # --- Step 1: SIGTERM ---
    Core::log INFO "Sending SIGTERM to PID ${_pid} (${_name})"
    if ! kill -TERM "${_pid}" 2>/dev/null; then
        Core::log WARN "SIGTERM failed for PID ${_pid} (${_name})"
        ProcessRecord::set action_taken "sigterm-failed"
        return 2
    fi

    # --- Step 2: non-blocking grace-wait loop ---
    Core::log INFO "Grace period ${_grace}s for PID ${_pid} (${_name})"
    while [[ ${_elapsed} -lt ${_grace} ]]; do
        if ! kill -0 "${_pid}" 2>/dev/null; then
            Core::log INFO "PID ${_pid} (${_name}) terminated gracefully after ${_elapsed}s"
            ProcessRecord::set action_taken "sigterm"
            return 0
        fi
        Core::msleep 0.2
        _elapsed=$(( _elapsed + 1 ))   # 0.2s * 5 = 1s per loop iteration approx
        # Note: _elapsed counts tenths; compare against grace*10
        if [[ ${_elapsed} -ge $(( _grace * 10 )) ]]; then
            break
        fi
    done

    # --- Step 3: SIGKILL escalation ---
    if kill -0 "${_pid}" 2>/dev/null; then
        Core::log WARN "PID ${_pid} (${_name}) refused SIGTERM; escalating to SIGKILL"
        if kill -KILL "${_pid}" 2>/dev/null; then
            Core::log INFO "SIGKILL sent to PID ${_pid} (${_name})"
            ProcessRecord::set action_taken "sigkill"
            return 1
        else
            Core::log ERROR "SIGKILL failed for PID ${_pid} (${_name})"
            ProcessRecord::set action_taken "sigkill-failed"
            return 2
        fi
    fi

    ProcessRecord::set action_taken "sigterm"
    return 0
}

###############################################################################
# Process::govern — scan for rogues and terminate each via cascade
#
# Usage: Process::govern [warn_mem_percent] [warn_cpu_percent] [grace_seconds]
###############################################################################
Process::govern() {
    local _warn_mem="${1:-$(Core::config_get warn_mem_percent 10)}"
    local _warn_cpu="${2:-$(Core::config_get warn_cpu_percent 10)}"
    local _grace="${3:-5}"
    local _pid _rc _terminated=0 _killed=0 _skipped=0 _failed=0

    Core::banner "Process Governor"
    Core::log INFO "Starting rogue process governance (mem>%=${_warn_mem}, cpu>%=${_warn_cpu}, grace=${_grace}s)"

    Process::scan_rogue "${_warn_mem}" "${_warn_cpu}"

    if [[ ${#Process_ROGUE_PIDS[@]} -eq 0 ]]; then
        Process::list_rogues
        return 0
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

        if Process::terminate_cascade "${_pid}" "${_grace}" "${Core_PROCESS_RECORD[name]}"; then
            _rc=$?
            case ${_rc} in
                0) _terminated=$(( _terminated + 1 )) ;;
                1) _killed=$(( _killed + 1 )) ;;
                2) _failed=$(( _failed + 1 )) ;;
            esac
        fi
    done

    printf '\n%bGovernor summary:%b terminated=%d sigkill=%d skipped(protected)=%d failed=%d\n' \
        "${Core_C_BOLD}" "${Core_C_RESET}" \
        "${_terminated}" "${_killed}" "${_skipped}" "${_failed}"

    Core::log INFO "Governor complete (terminated=${_terminated} sigkill=${_killed} skipped=${_skipped} failed=${_failed})"

    if [[ ${_failed} -gt 0 ]]; then
        return 1
    fi
    return 0
}

export -f Process::is_protected_pid Process::read_stat_fields \
          Process::compute_cpu_percent Process::get_system_cpu_total \
          Process::get_mem_total_kb Process::scan_rogue Process::list_rogues \
          Process::terminate_cascade Process::govern 2>/dev/null || true
