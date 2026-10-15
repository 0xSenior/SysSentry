#!/usr/bin/env bash
#
# lib/monitor.sh — SysSentry Monitor Module
#
# Virtual filesystem (/proc) inspector. Reads RAM usage, CPU load average, and
# IO saturation directly from kernel metrics in O(1) single-pass stream reads.
# Produces a SystemSnapshot entity and classifies health state:
#   NORMAL | WARNING | CRITICAL
#
# Namespace: Monitor:: (public), Monitor::_* (private)

###############################################################################
# Monitor::capture_snapshot
#
# Populates Core_SYSTEM_SNAPSHOT by reading:
#   /proc/meminfo   -> MemTotal, MemAvailable -> RAM utilisation %
#   /proc/loadavg   -> 1/5/15 minute load averages
#   /proc/stat      -> first aggregate "cpu " line -> CPU utilisation % + iowait
#
# Design notes:
#   - Single-pass reads per file; no command substitution inside loops.
#   - Fixed-point arithmetic (x10) avoids floating-point in Bash.
#   - /proc/stat CPU lines beyond the first aggregate "cpu " are per-core and
#     are intentionally skipped (break on first match).
#
# @return Core_EXIT_SUCCESS
###############################################################################
Monitor::capture_snapshot() {
    local -r _mem_total="$(Monitor::_read_meminfo_field MemTotal)"
    local -r _mem_avail="$(Monitor::_read_meminfo_field MemAvailable)"
    local -r _mem_used=$(( _mem_total - _mem_avail ))
    local -r _mem_pct=$(( _mem_total > 0 ? (_mem_used * 1000) / _mem_total : 0 ))

    local _l1="0.00" _l5="0.00" _l15="0.00"
    IFS=' ' read -r _l1 _l5 _l15 _ < /proc/loadavg || true

    local _cpu_user=0 _cpu_nice=0 _cpu_system=0 _cpu_idle=0
    local _cpu_iowait=0 _cpu_irq=0 _cpu_softirq=0 _cpu_steal=0
    local _label _u _n _s _i _w _irq _sirq _st _rest

    while IFS=' ' read -r _label _u _n _s _i _w _irq _sirq _st _rest; do
        if [[ "${_label}" == "cpu" ]]; then
            _cpu_user=${_u}; _cpu_nice=${_n}; _cpu_system=${_s}
            _cpu_idle=${_i}; _cpu_iowait=${_w}; _cpu_irq=${_irq}
            _cpu_softirq=${_sirq}; _cpu_steal=${_st}
            break
        fi
    done < /proc/stat

    local -i _cpu_total=0 _cpu_busy=0 _cpu_pct=0 _iowait_pct=0
    _cpu_total=$(( _cpu_user + _cpu_nice + _cpu_system + _cpu_idle +
                   _cpu_iowait + _cpu_irq + _cpu_softirq + _cpu_steal ))
    _cpu_busy=$(( _cpu_total - _cpu_idle - _cpu_iowait ))

    if [[ ${_cpu_total} -gt 0 ]]; then
        _cpu_pct=$(( (_cpu_busy * 1000) / _cpu_total ))
        _iowait_pct=$(( (_cpu_iowait * 1000) / _cpu_total ))
    fi

    SystemSnapshot::set timestamp "$(date '+%Y-%m-%d %H:%M:%S')"
    SystemSnapshot::set hostname "${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"
    SystemSnapshot::set mem_total_kb   "${_mem_total}"
    SystemSnapshot::set mem_available_kb "${_mem_avail}"
    SystemSnapshot::set mem_used_kb    "${_mem_used}"
    SystemSnapshot::set mem_percent    "$(( _mem_pct / 10 )).$(( _mem_pct % 10 ))"
    SystemSnapshot::set load_1min      "${_l1}"
    SystemSnapshot::set load_5min      "${_l5}"
    SystemSnapshot::set load_15min     "${_l15}"
    SystemSnapshot::set cpu_percent    "$(( _cpu_pct / 10 )).$(( _cpu_pct % 10 ))"
    SystemSnapshot::set io_wait_percent "$(( _iowait_pct / 10 )).$(( _iowait_pct % 10 ))"

    Monitor::_classify_health

    Core::log DEBUG "Snapshot captured (mem=${Core_SYSTEM_SNAPSHOT[mem_percent]}% cpu=${Core_SYSTEM_SNAPSHOT[cpu_percent]}% state=${Core_SYSTEM_SNAPSHOT[health_state]})"

    return "${Core_EXIT_SUCCESS}"
}

# Reads a single numeric field from /proc/meminfo (value in kB).
#
# @param field meminfo key (e.g. MemTotal, MemAvailable)
# @return field value as integer (0 if not found or unreadable)
Monitor::_read_meminfo_field() {
    local -r _field="${1:-}"
    local _key _val

    while IFS=: read -r _key _val || [[ -n "${_key}" ]]; do
        _key="${_key// /}"
        _val="${_val// /}"
        _val="${_val%%kB*}"
        if [[ "${_key}" == "${_field}" ]]; then
            echo "${_val}"
            return 0
        fi
    done < /proc/meminfo

    echo "0"
}

###############################################################################
# Monitor::_classify_health
#
# Categorises health based on thresholds from Core_CONFIG (O(1) lookups):
#   NORMAL   — all metrics below warning thresholds
#   WARNING  — any metric at/above warning but below critical
#   CRITICAL — any metric at/above critical threshold
#
# Comparison uses integer truncation of fixed-point percentages and load
# thresholds to avoid Bash floating-point limitations.
#
# @return None
###############################################################################
Monitor::_classify_health() {
    local -r _warn_mem="${Core_CONFIG[warn_mem_percent]:-80}"
    local -r _crit_mem="${Core_CONFIG[crit_mem_percent]:-90}"
    local -r _warn_cpu="${Core_CONFIG[warn_cpu_percent]:-75}"
    local -r _crit_cpu="${Core_CONFIG[crit_cpu_percent]:-85}"
    local -r _warn_load="${Core_CONFIG[warn_load_1min]:-4.0}"
    local -r _crit_load="${Core_CONFIG[crit_load_1min]:-8.0}"
    local -r _warn_io="${Core_CONFIG[warn_io_wait_percent]:-15}"
    local -r _crit_io="${Core_CONFIG[crit_io_wait_percent]:-30}"

    local -i _mem_pct_int _cpu_pct_int _io_pct_int _load1_int
    local -i _warn_mem_int _crit_mem_int _warn_cpu_int _crit_cpu_int
    local -i _warn_io_int _crit_io_int
    local _warn_load_int _crit_load_int

    _mem_pct_int="${Core_SYSTEM_SNAPSHOT[mem_percent]%.*}"
    _cpu_pct_int="${Core_SYSTEM_SNAPSHOT[cpu_percent]%.*}"
    _io_pct_int="${Core_SYSTEM_SNAPSHOT[io_wait_percent]%.*}"
    _load1_int="${Core_SYSTEM_SNAPSHOT[load_1min]%.*}"

    _warn_mem_int="${_warn_mem%.*}"
    _crit_mem_int="${_crit_mem%.*}"
    _warn_cpu_int="${_warn_cpu%.*}"
    _crit_cpu_int="${_crit_cpu%.*}"
    _warn_io_int="${_warn_io%.*}"
    _crit_io_int="${_crit_io%.*}"
    _warn_load_int="${_warn_load%.*}"
    _crit_load_int="${_crit_load%.*}"

    local _state="NORMAL"
    local -i _score=0

    if [[ ${_mem_pct_int} -ge ${_crit_mem_int} ]] || \
       [[ ${_cpu_pct_int} -ge ${_crit_cpu_int} ]] || \
       [[ ${_io_pct_int} -ge ${_crit_io_int} ]] || \
       [[ ${_load1_int} -ge ${_crit_load_int} ]]; then
        _state="CRITICAL"
        _score=3
    elif [[ ${_mem_pct_int} -ge ${_warn_mem_int} ]] || \
         [[ ${_cpu_pct_int} -ge ${_warn_cpu_int} ]] || \
         [[ ${_io_pct_int} -ge ${_warn_io_int} ]] || \
         [[ ${_load1_int} -ge ${_warn_load_int} ]]; then
        _state="WARNING"
        _score=2
    fi

    SystemSnapshot::set health_state "${_state}"
    SystemSnapshot::set health_score "${_score}"
}

###############################################################################
# Monitor::display_snapshot
#
# Renders a rich terminal UI of the current SystemSnapshot with ANSI colours.
# Thresholds are read directly from Core_CONFIG (O(1)) to avoid subshells.
#
# @return Core_EXIT_SUCCESS
###############################################################################
Monitor::display_snapshot() {
    local -r _state="${Core_SYSTEM_SNAPSHOT[health_state]}"
    local -r _mem="${Core_SYSTEM_SNAPSHOT[mem_percent]}"
    local -r _cpu="${Core_SYSTEM_SNAPSHOT[cpu_percent]}"
    local -r _io="${Core_SYSTEM_SNAPSHOT[io_wait_percent]}"
    local -r _l1="${Core_SYSTEM_SNAPSHOT[load_1min]}"
    local -r _l5="${Core_SYSTEM_SNAPSHOT[load_5min]}"
    local -r _l15="${Core_SYSTEM_SNAPSHOT[load_15min]}"
    local -r _host="${Core_SYSTEM_SNAPSHOT[hostname]}"
    local -r _ts="${Core_SYSTEM_SNAPSHOT[timestamp]}"

    local _state_colour _state_label
    case "${_state}" in
        NORMAL)  _state_colour="${Core_C_GREEN}"  ; _state_label="NORMAL"  ;;
        WARNING) _state_colour="${Core_C_YELLOW}" ; _state_label="WARNING" ;;
        CRITICAL) _state_colour="${Core_C_RED}"   ; _state_label="CRITICAL" ;;
        *)       _state_colour="${Core_C_RESET}"  ; _state_label="UNKNOWN" ;;
    esac

    printf '%b%s%b\n' "${Core_C_BOLD}${Core_C_CYAN}" "┌─ SysSentry System Snapshot ─" "${Core_C_RESET}"
    printf '  %bHost:%b      %s\n' "${Core_C_DIM}" "${Core_C_RESET}" "${_host}"
    printf '  %bTime:%b      %s\n' "${Core_C_DIM}" "${Core_C_RESET}" "${_ts}"
    printf '\n'
    printf '  %bResource%%│%b %%Used   %bThreshold%%%b\n' "${Core_C_BOLD}" "${Core_C_RESET}" "${Core_C_BOLD}" "${Core_C_RESET}"
    printf '  %b─────────┼%b──────────────────\n' "${Core_C_DIM}" "${Core_C_RESET}"
    printf '  MEM    │ %s%4s%%%b   (warn %s / crit %s)\n' \
        "${Core_C_GREEN}" "${_mem}" "${Core_C_RESET}" \
        "${Core_CONFIG[warn_mem_percent]:-80}" "${Core_CONFIG[crit_mem_percent]:-90}"
    printf '  CPU    │ %s%4s%%%b   (warn %s / crit %s)\n' \
        "${Core_C_GREEN}" "${_cpu}" "${Core_C_RESET}" \
        "${Core_CONFIG[warn_cpu_percent]:-75}" "${Core_CONFIG[crit_cpu_percent]:-85}"
    printf '  IOwait │ %s%4s%%%b   (warn %s / crit %s)\n' \
        "${Core_C_GREEN}" "${_io}" "${Core_C_RESET}" \
        "${Core_CONFIG[warn_io_wait_percent]:-15}" "${Core_CONFIG[crit_io_wait_percent]:-30}"
    printf '\n'
    printf '  %bLoad avg:%b  1m=%s  5m=%s  15m=%s\n' \
        "${Core_C_DIM}" "${Core_C_RESET}" "${_l1}" "${_l5}" "${_l15}"
    printf '\n'
    printf '  %bHealth:%b    %b%s%b  (score=%s)\n' \
        "${Core_C_DIM}" "${Core_C_RESET}" \
        "${_state_colour}${Core_C_BOLD}" "${_state_label}" "${Core_C_RESET}" \
        "${Core_SYSTEM_SNAPSHOT[health_score]}"
    printf '%b└────────────────────────────────%b\n\n' "${Core_C_BOLD}${Core_C_CYAN}" "${Core_C_RESET}"

    return "${Core_EXIT_SUCCESS}"
}

# Returns true (0) if the last captured snapshot health state is CRITICAL.
# Used by the backup pre-flight safety gate.
#
# @return Core_EXIT_SUCCESS if CRITICAL, Core_ERR_GENERAL otherwise
Monitor::health_is_critical() {
    [[ "${Core_SYSTEM_SNAPSHOT[health_state]}" == "CRITICAL" ]]
}
