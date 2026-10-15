#!/usr/bin/env bash
#
# lib/core.sh — SysSentry Core Module
#
# Pseudo-OOP entity structs, structured logger, signal traps, defensive error
# handling, and O(1) runtime configuration cache.
#
# Namespace: Core:: (public), Core::_* (private)

set -euo pipefail

###############################################################################
# Standardized exit status codes
###############################################################################
declare -ir Core_EXIT_SUCCESS=0
declare -ir Core_ERR_GENERAL=1
declare -ir Core_ERR_USAGE=2
declare -ir Core_ERR_PERMISSION=11
declare -ir Core_ERR_RESOURCE_PRESSURE=10
declare -ir Core_ERR_CONFIG=12
declare -ir Core_ERR_IO=13
declare -ir Core_ERR_PROCESS=14
declare -ir Core_ERR_BACKUP=15

###############################################################################
# Global state (namespace: Core)
###############################################################################
declare -r Core_VERSION="2.0.0"
declare -r Core_PROJECT_NAME="SysSentry"
declare -r Core_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
declare -r Core_LIB_DIR="${Core_ROOT_DIR}/lib"
declare -r Core_CONFIG_DIR="${Core_ROOT_DIR}/config"
declare -r Core_CONFIG_FILE="${Core_CONFIG_DIR}/syssentry.conf"

declare -A Core_CONFIG=()

declare -A Core_SYSTEM_SNAPSHOT=(
    [timestamp]=""
    [hostname]=""
    [mem_total_kb]="0"
    [mem_available_kb]="0"
    [mem_used_kb]="0"
    [mem_percent]="0"
    [load_1min]="0.00"
    [load_5min]="0.00"
    [load_15min]="0.00"
    [cpu_percent]="0.00"
    [io_wait_percent]="0.00"
    [health_state]="NORMAL"
    [health_score]="0"
)

declare -A Core_PROCESS_RECORD=(
    [pid]="0"
    [ppid]="0"
    [name]=""
    [state]=""
    [cpu_percent]="0.00"
    [mem_rss_kb]="0"
    [mem_vsize_kb]="0"
    [mem_percent]="0.00"
    [rogue]="false"
    [action_taken]="none"
)

declare -A Core_BACKUP_JOB=(
    [job_id]=""
    [source]=""
    [destination]=""
    [archive_name]=""
    [snapshot_file]=""
    [type]="full"
    [status]="pending"
    [bytes]="0"
    [duration_sec]="0"
    [error_message]=""
)

declare -A Core_PROTECTED_PIDS=()

declare -i Core_EXITING=0
declare -i Core_EXIT_CODE=0
declare -i Core_EXIT_HANDLED=0

declare -a Core_TEMP_FILES=()

declare -r Core_LOG_FILE="${Core_ROOT_DIR}/syssentry.log"

declare -r Core_C_RESET='\033[0m'
declare -r Core_C_BOLD='\033[1m'
declare -r Core_C_DIM='\033[2m'
declare -r Core_C_RED='\033[31m'
declare -r Core_C_GREEN='\033[32m'
declare -r Core_C_YELLOW='\033[33m'
declare -r Core_C_BLUE='\033[34m'
declare -r Core_C_MAGENTA='\033[35m'
declare -r Core_C_CYAN='\033[36m'
declare -r Core_C_WHITE='\033[37m'
declare -r Core_C_BG_RED='\033[41m'
declare -r Core_C_BG_GREEN='\033[42m'
declare -r Core_C_BG_YELLOW='\033[43m'

###############################################################################
# Entity constructors / accessors — SystemSnapshot
###############################################################################

# Resets the SystemSnapshot entity to default values.
#
# @return None
SystemSnapshot::new() {
    local -r _ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local -r _hn="${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"

    Core_SYSTEM_SNAPSHOT[timestamp]="${_ts}"
    Core_SYSTEM_SNAPSHOT[hostname]="${_hn}"
    Core_SYSTEM_SNAPSHOT[mem_total_kb]="0"
    Core_SYSTEM_SNAPSHOT[mem_available_kb]="0"
    Core_SYSTEM_SNAPSHOT[mem_used_kb]="0"
    Core_SYSTEM_SNAPSHOT[mem_percent]="0"
    Core_SYSTEM_SNAPSHOT[load_1min]="0.00"
    Core_SYSTEM_SNAPSHOT[load_5min]="0.00"
    Core_SYSTEM_SNAPSHOT[load_15min]="0.00"
    Core_SYSTEM_SNAPSHOT[cpu_percent]="0.00"
    Core_SYSTEM_SNAPSHOT[io_wait_percent]="0.00"
    Core_SYSTEM_SNAPSHOT[health_state]="NORMAL"
    Core_SYSTEM_SNAPSHOT[health_score]="0"
}

# Returns the value of a SystemSnapshot field in O(1).
#
# @param key entity field name
# @return field value (empty string if unset)
SystemSnapshot::get() {
    local -r _key="${1:-}"

    if [[ -z "${_key}" ]]; then
        Core::log WARN "SystemSnapshot::get called with empty key"
        echo ""
        return 0
    fi

    echo "${Core_SYSTEM_SNAPSHOT[${_key}]:-}"
}

# Sets a SystemSnapshot field in O(1).
#
# @param key entity field name
# @param value value to assign
# @return None
SystemSnapshot::set() {
    local -r _key="${1:-}"
    local -r _val="${2:-}"

    if [[ -z "${_key}" ]]; then
        Core::log WARN "SystemSnapshot::set called with empty key"
        return 0
    fi

    Core_SYSTEM_SNAPSHOT[${_key}]="${_val}"
}

###############################################################################
# Entity constructors / accessors — ProcessRecord
###############################################################################

# Resets the ProcessRecord entity to default values.
#
# @return None
ProcessRecord::new() {
    Core_PROCESS_RECORD[pid]="0"
    Core_PROCESS_RECORD[ppid]="0"
    Core_PROCESS_RECORD[name]=""
    Core_PROCESS_RECORD[state]=""
    Core_PROCESS_RECORD[cpu_percent]="0.00"
    Core_PROCESS_RECORD[mem_rss_kb]="0"
    Core_PROCESS_RECORD[mem_vsize_kb]="0"
    Core_PROCESS_RECORD[mem_percent]="0.00"
    Core_PROCESS_RECORD[rogue]="false"
    Core_PROCESS_RECORD[action_taken]="none"
}

# Returns the value of a ProcessRecord field in O(1).
#
# @param key entity field name
# @return field value (empty string if unset)
ProcessRecord::get() {
    local -r _key="${1:-}"
    echo "${Core_PROCESS_RECORD[${_key}]:-}"
}

# Sets a ProcessRecord field in O(1).
#
# @param key entity field name
# @param value value to assign
# @return None
ProcessRecord::set() {
    local -r _key="${1:-}"
    local -r _val="${2:-}"
    Core_PROCESS_RECORD[${_key}]="${_val}"
}

###############################################################################
# Entity constructors / accessors — BackupJob
###############################################################################

# Resets the BackupJob entity to default values.
#
# @return None
BackupJob::new() {
    local -r _jid="sentry-$(date '+%Y%m%d%H%M%S')"

    Core_BACKUP_JOB[job_id]="${_jid}"
    Core_BACKUP_JOB[source]=""
    Core_BACKUP_JOB[destination]=""
    Core_BACKUP_JOB[archive_name]=""
    Core_BACKUP_JOB[snapshot_file]=""
    Core_BACKUP_JOB[type]="full"
    Core_BACKUP_JOB[status]="pending"
    Core_BACKUP_JOB[bytes]="0"
    Core_BACKUP_JOB[duration_sec]="0"
    Core_BACKUP_JOB[error_message]=""
}

# Returns the value of a BackupJob field in O(1).
#
# @param key entity field name
# @return field value (empty string if unset)
BackupJob::get() {
    local -r _key="${1:-}"
    echo "${Core_BACKUP_JOB[${_key}]:-}"
}

# Sets a BackupJob field in O(1).
#
# @param key entity field name
# @param value value to assign
# @return None
BackupJob::set() {
    local -r _key="${1:-}"
    local -r _val="${2:-}"
    Core_BACKUP_JOB[${_key}]="${_val}"
}

###############################################################################
# Logger
###############################################################################

# Writes a structured event to syssentry.log and, when a terminal is attached,
# to stdout with ANSI colour coding.
#
# @param level log level (DEBUG|INFO|WARN|ERROR|CRIT)
# @param message event message
# @param details optional contextual details
# @return None
Core::log() {
    local -r _level="${1:-INFO}"
    local -r _message="${2:-}"
    local -r _details="${3:-}"
    local _ts _colour

    _ts="$(date '+%Y-%m-%d %H:%M:%S')"

    case "${_level}" in
        DEBUG)  _colour="${Core_C_CYAN}"   ;;
        INFO)   _colour="${Core_C_GREEN}"  ;;
        WARN)   _colour="${Core_C_YELLOW}" ;;
        ERROR)  _colour="${Core_C_RED}"    ;;
        CRIT)   _colour="${Core_C_BG_RED}${Core_C_WHITE}" ;;
        *)      _colour="${Core_C_RESET}"  ;;
    esac

    if [[ -n "${Core_LOG_FILE}" && -w "$(dirname "${Core_LOG_FILE}")" ]]; then
        if [[ -n "${_details}" ]]; then
            printf '[%s] [%s] %s | %s\n' \
                "${_ts}" "${_level}" "${_message}" "${_details}" \
                >> "${Core_LOG_FILE}" 2>/dev/null || true
        else
            printf '[%s] [%s] %s\n' \
                "${_ts}" "${_level}" "${_message}" \
                >> "${Core_LOG_FILE}" 2>/dev/null || true
        fi
    fi

    if [[ -t 1 ]]; then
        if [[ -n "${_details}" ]]; then
            printf '%b[%s] [%b%s%b] %s | %s%b\n' \
                "${Core_C_DIM}" "${_ts}" "${_colour}" "${_level}" "${Core_C_RESET}" \
                "${_message}" "${_details}" "${Core_C_RESET}"
        else
            printf '%b[%s] [%b%s%b] %s%b\n' \
                "${Core_C_DIM}" "${_ts}" "${_colour}" "${_level}" "${Core_C_RESET}" \
                "${_message}" "${Core_C_RESET}"
        fi
    fi
}

# Wraps text in ANSI colour based on log level. Private helper.
#
# @param level log level
# @param text text to colourise
# @return coloured text string
Core::_colourise() {
    local -r _level="${1:-}"
    local -r _text="${2:-}"
    local _c

    case "${_level}" in
        DEBUG) _c="${Core_C_CYAN}"   ;;
        INFO)  _c="${Core_C_GREEN}"  ;;
        WARN)  _c="${Core_C_YELLOW}" ;;
        ERROR) _c="${Core_C_RED}"    ;;
        CRIT)  _c="${Core_C_BG_RED}${Core_C_WHITE}" ;;
        *)     _c="${Core_C_RESET}"  ;;
    esac

    printf '%b%s%b' "${_c}" "${_text}" "${Core_C_RESET}"
}

###############################################################################
# Initialisation
###############################################################################

# Bootstraps the application: loads configuration, builds the PID protection
# whitelist, installs signal traps, and initialises all entity structs.
#
# @return Core_EXIT_SUCCESS on success
Core::init() {
    SystemSnapshot::new
    ProcessRecord::new
    BackupJob::new

    Core::_load_config

    Core_PROTECTED_PIDS[$$]="self"
    Core_PROTECTED_PIDS[$PPID]="parent"
    Core_PROTECTED_PIDS[1]="init"

    local _pid
    for _pid in 2 3 4 5 6 7 8; do
        Core_PROTECTED_PIDS[$_pid]="kernel-daemon"
    done

    local _cfg_val
    _cfg_val="$(Core::config_get protected_pids "")"
    if [[ -n "${_cfg_val}" ]]; then
        local -a _pids=()
        IFS=',' read -ra _pids <<< "${_cfg_val}"
        for _pid in "${_pids[@]}"; do
            _pid="${_pid// /}"
            if [[ "${_pid}" =~ ^[0-9]+$ ]]; then
                Core_PROTECTED_PIDS[$_pid]="configured"
            fi
        done
    fi

    trap 'Core::cleanup; Core::handle_error $? $LINENO' ERR
    trap 'Core::cleanup; Core::handle_error $? $LINENO' EXIT
    trap 'Core::cleanup; Core::handle_error $? $LINENO' INT
    trap 'Core::cleanup; Core::handle_error $? $LINENO' TERM

    Core::log INFO "SysSentry v${Core_VERSION} initialised (pid=$$)"

    return "${Core_EXIT_SUCCESS}"
}

# Parses syssentry.conf into the Core_CONFIG hash map for O(1) lookups.
# Supports KEY=value lines, inline comments, and blank lines. Private helper.
#
# @param config_file path to configuration file (default: Core_CONFIG_FILE)
# @return Core_EXIT_SUCCESS
Core::_load_config() {
    local -r _cfg_file="${1:-${Core_CONFIG_FILE:-}}"

    if [[ -z "${_cfg_file}" || ! -f "${_cfg_file}" ]]; then
        Core::log WARN "Config file not found: ${_cfg_file:-<unset>} (using defaults)"
        return "${Core_EXIT_SUCCESS}"
    fi

    local _line _key _val
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        _line="${_line#"${_line%%[![:space:]]*}"}"
        _line="${_line%"${_line##*[![:space:]]}"}"

        [[ -z "${_line}" || "${_line}" == \#* ]] && continue

        if [[ "${_line}" == *"="* ]]; then
            _key="${_line%%=*}"
            _val="${_line#*=}"
            _key="${_key#"${_key%%[![:space:]]*}"}"
            _key="${_key%"${_key##*[![:space:]]}"}"
            _val="${_val#"${_val%%[![:space:]]*}"}"
            _val="${_val%"${_val##*[![:space:]]}"}"

            if [[ "${_val}" == *" #"* ]]; then
                _val="${_val%% #*}"
                _val="${_val%"${_val##*[![:space:]]}"}"
            fi

            Core_CONFIG[${_key}]="${_val}"
        fi
    done < "${_cfg_file}"

    Core::log DEBUG "Configuration loaded (${#Core_CONFIG[@]} entries)"

    return "${Core_EXIT_SUCCESS}"
}

# Returns a configuration value in O(1) with an optional default fallback.
#
# @param key configuration key
# @param default default value if key is absent
# @return configuration value or default
Core::config_get() {
    local -r _key="${1:-}"
    local -r _default="${2:-}"

    if [[ -z "${_key}" ]]; then
        echo "${_default}"
        return 0
    fi

    if [[ -v "Core_CONFIG[${_key}]" ]]; then
        echo "${Core_CONFIG[${_key}]}"
    else
        echo "${_default}"
    fi
}

###############################################################################
# Error handling & cleanup
###############################################################################

# Central error handler. Idempotent: only the first non-zero invocation is
# logged; subsequent calls (e.g. EXIT trap following ERR trap) are no-ops.
#
# @param code exit code
# @param line line number where the error occurred
# @return None
Core::handle_error() {
    local -r _code="${1:-0}"
    local -r _line="${2:-0}"

    if [[ ${Core_EXIT_HANDLED} -eq 1 ]]; then
        return 0
    fi
    Core_EXIT_HANDLED=1

    if [[ ${_code} -eq 0 ]]; then
        Core::log INFO "SysSentry exited cleanly (code 0)"
        return 0
    fi

    Core_EXITING=1
    Core_EXIT_CODE=${_code}

    Core::log ERROR "SysSentry fatal error (exit code ${_code}) at line ${_line}"
    printf '%b%s%b: %s exited with code %s at line %s\n' \
        "${Core_C_BG_RED}${Core_C_WHITE}" "FATAL" "${Core_C_RESET}" \
        "${Core_PROJECT_NAME}" "${_code}" "${_line}" >&2
}

# Removes registered temporary files and resets exit guard state.
#
# @return None
Core::cleanup() {
    local _tmp
    for _tmp in "${Core_TEMP_FILES[@]:-}"; do
        if [[ -n "${_tmp}" && -f "${_tmp}" ]]; then
            rm -f "${_tmp}" 2>/dev/null || true
        fi
    done
    Core_TEMP_FILES=()
}

# Registers a temporary file for removal during cleanup.
#
# @param file path to temporary file
# @return None
Core::register_temp() {
    local -r _f="${1:-}"
    if [[ -n "${_f}" ]]; then
        Core_TEMP_FILES+=("${_f}")
    fi
}

###############################################################################
# Helpers
###############################################################################

# Returns true (0) if the effective user is root (UID 0).
#
# @return Core_EXIT_SUCCESS if root, Core_ERR_PERMISSION otherwise
Core::is_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]]
}

# Aborts with Core_ERR_PERMISSION if not running as root.
#
# @return Core_EXIT_SUCCESS if root, Core_ERR_PERMISSION otherwise
Core::require_root() {
    if ! Core::is_root; then
        Core::log ERROR "Operation requires root privileges (current UID=${EUID:-unknown})"
        return "${Core_ERR_PERMISSION}"
    fi
    return "${Core_EXIT_SUCCESS}"
}

# Returns true (0) if the string is a valid integer.
#
# @param s string to validate
# @return Core_EXIT_SUCCESS if integer, Core_ERR_GENERAL otherwise
Core::is_integer() {
    local -r _s="${1:-}"
    [[ "${_s}" =~ ^-?[0-9]+$ ]]
}

# Returns true (0) if the string is a valid number (integer or float).
#
# @param s string to validate
# @return Core_EXIT_SUCCESS if numeric, Core_ERR_GENERAL otherwise
Core::is_number() {
    local -r _s="${1:-}"
    [[ "${_s}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]
}

# Sleeps for a fractional number of seconds.
#
# @param seconds sleep duration (default: 0.2)
# @return None
Core::msleep() {
    local -r _secs="${1:-0.2}"
    sleep "${_secs}"
}

# Prints a section banner to stdout when a terminal is attached.
#
# @param title section title
# @return None
Core::banner() {
    local -r _title="${1:-SysSentry}"
    local _width=60

    if [[ -t 1 ]]; then
        _width="$(tput cols 2>/dev/null || echo 60)"
        [[ "${_width}" =~ ^[0-9]+$ ]] || _width=60
    fi

    printf '\n%b=== %s ===%b\n\n' "${Core_C_BOLD}${Core_C_CYAN}" "${_title}" "${Core_C_RESET}"
}
