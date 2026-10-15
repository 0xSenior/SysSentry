#!/usr/bin/env bash
#
# lib/monitor.sh — SysSentry Monitor Module
#
# Virtual filesystem (/proc) inspector. Reads RAM usage, CPU load average, and
# IO saturation directly from kernel metrics in O(1) single-pass stream reads
# (no subshell bottlenecks inside loops).
#
# Produces a structured SystemSnapshot entity and classifies health state:
#   NORMAL | WARNING | CRITICAL
#
# Namespace: Monitor::

###############################################################################
# Monitor::capture_snapshot
#
# Populates Core_SYSTEM_SNAPSHOT (pseudo-OOP struct) by reading:
#   /proc/meminfo   -> MemTotal, MemAvailable -> RAM utilisation %
#   /proc/loadavg   -> 1/5/15 minute load averages
#   /proc/stat      -> CPU jiffies (first "cpu " line) -> CPU utilisation % + iowait
#
# Design: single-pass reads per file; no command substitution inside loops;
# arithmetic done in Bash native built-ins.
###############################################################################
Monitor::capture_snapshot() {
    local _mem_total=0 _mem_avail=0 _mem_used=0 _mem_pct=0
    local _load1="0.00" _load5="0.00" _load15="0.00"
    local _cpu_user=0 _cpu_nice=0 _cpu_system=0 _cpu_idle=0
    local _cpu_iowait=0 _cpu_irq=0 _cpu_softirq=0 _cpu_steal=0
    local _cpu_total=0 _cpu_busy=0 _cpu_pct=0 _iowait_pct=0
    local _line _key _val

    # --- /proc/meminfo (single-pass) ---
    # Format: "MemTotal:       12345 kB"
    while IFS=: read -r _key _val || [[ -n "${_key}" ]]; do
        _key="${_key// /}"      # strip spaces -> "MemTotal"
        _val="${_val// /}"      # strip spaces -> "12345kB"
        _val="${_val%%kB*}"     # strip unit suffix -> "12345"
        case "${_key}" in
            MemTotal)   _mem_total=${_val} ;;
            MemAvailable) _mem_avail=${_val} ;;
        esac
    done < /proc/meminfo

    _mem_used=$(( _mem_total - _mem_avail ))
    if [[ ${_mem_total} -gt 0 ]]; then
        _mem_pct=$(( (_mem_used * 1000) / _mem_total ))   # fixed-point x10
    else
        _mem_pct=0
    fi

    # --- /proc/loadavg (single-field read) ---
    # Format: "0.00 0.01 0.05 1/234 1234"
    {
        IFS=' ' read -r _load1 _load5 _load15 _rest || true
    } < /proc/loadavg

    # --- /proc/stat (single "cpu " aggregate line) ---
    # Format: "cpu  123 45 67 890 10 11 12 13 14 15"
    while IFS=' ' read -r _cpu_label _cpu_user _cpu_nice _cpu_system _cpu_idle \
                         _cpu_iowait _cpu_irq _cpu_softirq _cpu_steal _rest; do
        if [[ "${_cpu_label}" == "cpu" ]]; then
            break   # first aggregate line only
        fi
    done < /proc/stat

    _cpu_total=$(( _cpu_user + _cpu_nice + _cpu_system + _cpu_idle +
                   _cpu_iowait + _cpu_irq + _cpu_softirq + _cpu_steal ))
    _cpu_busy=$(( _cpu_total - _cpu_idle - _cpu_iowait ))
    if [[ ${_cpu_total} -gt 0 ]]; then
        _cpu_pct=$(( (_cpu_busy * 1000) / _cpu_total ))   # fixed-point x10
        _iowait_pct=$(( (_cpu_iowait * 1000) / _cpu_total ))
    else
        _cpu_pct=0
        _iowait_pct=0
    fi

    # --- Populate SystemSnapshot entity (O(1) writes) ---
    SystemSnapshot::set timestamp "$(date '+%Y-%m-%d %H:%M:%S')"
    SystemSnapshot::set hostname "${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"
    SystemSnapshot::set mem_total_kb   "${_mem_total}"
    SystemSnapshot::set mem_available_kb "${_mem_avail}"
    SystemSnapshot::set mem_used_kb    "${_mem_used}"
    SystemSnapshot::set mem_percent    "$(( _mem_pct / 10 )).$(( _mem_pct % 10 ))"
    SystemSnapshot::set load_1min      "${_load1}"
    SystemSnapshot::set load_5min      "${_load5}"
    SystemSnapshot::set load_15min     "${_load15}"
    SystemSnapshot::set cpu_percent    "$(( _cpu_pct / 10 )).$(( _cpu_pct % 10 ))"
    SystemSnapshot::set io_wait_percent "$(( _iowait_pct / 10 )).$(( _iowait_pct % 10 ))"

    # --- Classify health state ---
    Monitor::classify_health

    Core::log DEBUG "Snapshot captured (mem=${Core_SYSTEM_SNAPSHOT[mem_percent]}% cpu=${Core_SYSTEM_SNAPSHOT[cpu_percent]}% state=${Core_SYSTEM_SNAPSHOT[health_state]})"
}

###############################################################################
# Monitor::classify_health
#
# Categorises health based on thresholds from Core_CONFIG (O(1) lookups):
#   NORMAL   — all metrics below warning thresholds
#   WARNING  — any metric at/above warning but below critical
#   CRITICAL — any metric at/above critical threshold
###############################################################################
Monitor::classify_health() {
    local _warn_mem _crit_mem _warn_cpu _crit_cpu _warn_load _crit_load _warn_io _crit_io
    local _mem_pct_int _cpu_pct_int _io_pct_int
    local _load1_int
    local _state="NORMAL" _score=0

    # Read thresholds (O(1) hash-map lookups, with sensible defaults)
    _warn_mem="$(Core::config_get warn_mem_percent 80)"
    _crit_mem="$(Core::config_get crit_mem_percent 90)"
    _warn_cpu="$(Core::config_get warn_cpu_percent 75)"
    _crit_cpu="$(Core::config_get crit_cpu_percent 85)"
    _warn_load="$(Core::config_get warn_load_1min 4.0)"
    _crit_load="$(Core::config_get crit_load_1min 8.0)"
    _warn_io="$(Core::config_get warn_io_wait_percent 15)"
    _crit_io="$(Core::config_get crit_io_wait_percent 30)"

    # Convert snapshot percents to integers for comparison (strip decimals)
    _mem_pct_int="${Core_SYSTEM_SNAPSHOT[mem_percent]%.*}"
    _cpu_pct_int="${Core_SYSTEM_SNAPSHOT[cpu_percent]%.*}"
    _io_pct_int="${Core_SYSTEM_SNAPSHOT[io_wait_percent]%.*}"
    _load1_int="${Core_SYSTEM_SNAPSHOT[load_1min]%.*}"
    [[ -z "${_mem_pct_int}" ]] && _mem_pct_int=0
    [[ -z "${_cpu_pct_int}" ]] && _cpu_pct_int=0
    [[ -z "${_io_pct_int}" ]] && _io_pct_int=0
    [[ -z "${_load1_int}" ]] && _load1_int=0

    # Convert load thresholds to integers (strip decimals) for -ge comparison
    _warn_load_int="${_warn_load%.*}"
    _crit_load_int="${_crit_load%.*}"
    [[ -z "${_warn_load_int}" ]] && _warn_load_int=0
    [[ -z "${_crit_load_int}" ]] && _crit_load_int=0

    # --- Critical checks (highest severity wins) ---
    if [[ ${_mem_pct_int} -ge ${_crit_mem} ]] || \
       [[ ${_cpu_pct_int} -ge ${_crit_cpu} ]] || \
       [[ ${_io_pct_int} -ge ${_crit_io} ]] || \
       [[ ${_load1_int} -ge ${_crit_load_int} ]]; then
        _state="CRITICAL"
        _score=3
    # --- Warning checks ---
    elif [[ ${_mem_pct_int} -ge ${_warn_mem} ]] || \
         [[ ${_cpu_pct_int} -ge ${_warn_cpu} ]] || \
         [[ ${_io_pct_int} -ge ${_warn_io} ]] || \
         [[ ${_load1_int} -ge ${_warn_load_int} ]]; then
        _state="WARNING"
        _score=2
    else
        _state="NORMAL"
        _score=0
    fi

    SystemSnapshot::set health_state "${_state}"
    SystemSnapshot::set health_score "${_score}"
}

###############################################################################
# Monitor::display_snapshot — rich terminal UI output
###############################################################################
Monitor::display_snapshot() {
    local _state_colour _state_label _mem _cpu _io _l1 _l5 _l15 _host _ts

    _mem="${Core_SYSTEM_SNAPSHOT[mem_percent]}"
    _cpu="${Core_SYSTEM_SNAPSHOT[cpu_percent]}"
    _io="${Core_SYSTEM_SNAPSHOT[io_wait_percent]}"
    _l1="${Core_SYSTEM_SNAPSHOT[load_1min]}"
    _l5="${Core_SYSTEM_SNAPSHOT[load_5min]}"
    _l15="${Core_SYSTEM_SNAPSHOT[load_15min]}"
    _host="${Core_SYSTEM_SNAPSHOT[hostname]}"
    _ts="${Core_SYSTEM_SNAPSHOT[timestamp]}"

    case "${Core_SYSTEM_SNAPSHOT[health_state]}" in
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
        "$(Core::config_get warn_mem_percent 80)" "$(Core::config_get crit_mem_percent 90)"
    printf '  CPU    │ %s%4s%%%b   (warn %s / crit %s)\n' \
        "${Core_C_GREEN}" "${_cpu}" "${Core_C_RESET}" \
        "$(Core::config_get warn_cpu_percent 75)" "$(Core::config_get crit_cpu_percent 85)"
    printf '  IOwait │ %s%4s%%%b   (warn %s / crit %s)\n' \
        "${Core_C_GREEN}" "${_io}" "${Core_C_RESET}" \
        "$(Core::config_get warn_io_wait_percent 15)" "$(Core::config_get crit_io_wait_percent 30)"
    printf '\n'
    printf '  %bLoad avg:%b  1m=%s  5m=%s  15m=%s\n' \
        "${Core_C_DIM}" "${Core_C_RESET}" "${_l1}" "${_l5}" "${_l15}"
    printf '\n'
    printf '  %bHealth:%b    %b%s%b  (score=%s)\n' \
        "${Core_C_DIM}" "${Core_C_RESET}" \
        "${_state_colour}${Core_C_BOLD}" "${_state_label}" "${Core_C_RESET}" \
        "${Core_SYSTEM_SNAPSHOT[health_score]}"
    printf '%b└────────────────────────────────%b\n\n' "${Core_C_BOLD}${Core_C_CYAN}" "${Core_C_RESET}"
}

###############################################################################
# Monitor::health_is_critical — boolean gate for the backup pre-flight check
###############################################################################
Monitor::health_is_critical() {
    [[ "${Core_SYSTEM_SNAPSHOT[health_state]}" == "CRITICAL" ]]
}

export -f Monitor::capture_snapshot Monitor::classify_health \
          Monitor::display_snapshot Monitor::health_is_critical 2>/dev/null || true
