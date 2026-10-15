#!/usr/bin/env bash
#
# lib/core.sh — SysSentry Core Module
#
# Pseudo-OOP simulation, structured logger, signal traps, defensive error
# handling, and runtime configuration cache for the SysSentry system utility.
#
# Namespace: Core::
#
# Design principles:
#   - set -euo pipefail (defensive mode)
#   - Every internal function variable strictly scoped with `local` / `local -r`
#   - Trap ERR / EXIT / INT / TERM safely
#   - O(1) configuration lookups via Bash associative arrays
#   - Zero subshell bottlenecks in hot paths
#

###############################################################################
# Strict defensive mode
###############################################################################
set -euo pipefail

###############################################################################
# Global state (namespace: Core)
###############################################################################
declare -r Core_VERSION="2.0.0"
declare -r Core_PROJECT_NAME="SysSentry"
declare -r Core_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
declare -r Core_LIB_DIR="${Core_ROOT_DIR}/lib"
declare -r Core_CONFIG_DIR="${Core_ROOT_DIR}/config"
declare -r Core_CONFIG_FILE="${Core_CONFIG_DIR}/syssentry.conf"

# Runtime configuration cache (O(1) hash-map lookups)
declare -A Core_CONFIG=()

# SystemSnapshot entity (pseudo-OOP struct via associative array)
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

# ProcessRecord entity template (pseudo-OOP struct via associative array)
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

# BackupJob entity template (pseudo-OOP struct via associative array)
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

# PID protection whitelist (O(1) lookups) — PIDs that must never be terminated
declare -A Core_PROTECTED_PIDS=()

# Signal / exit guard flags (prevent double-handling)
declare -i Core_EXITING=0
declare -i Core_EXIT_CODE=0

# Temp file registry for cleanup
declare -a Core_TEMP_FILES=()

# Log file path
declare -r Core_LOG_FILE="${Core_ROOT_DIR}/syssentry.log"

# ANSI colour palette (rich terminal interface)
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
# Constructor / accessor — SystemSnapshot
###############################################################################

# SystemSnapshot::new — reset the snapshot entity to defaults
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

# SystemSnapshot::get — O(1) accessor for a snapshot field
# Usage: SystemSnapshot::get mem_percent
SystemSnapshot::get() {
    local -r _key="${1:-}"
    if [[ -z "${_key}" ]]; then
        Core::log WARN "SystemSnapshot::get called with empty key"
        echo ""
        return 0
    fi
    echo "${Core_SYSTEM_SNAPSHOT[${_key}]:-}"
}

# SystemSnapshot::set — O(1) mutator for a snapshot field
# Usage: SystemSnapshot::set mem_percent 42.5
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
# Constructor / accessor — ProcessRecord
###############################################################################

# ProcessRecord::new — reset the process record entity
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

# ProcessRecord::get — O(1) accessor
ProcessRecord::get() {
    local -r _key="${1:-}"
    echo "${Core_PROCESS_RECORD[${_key}]:-}"
}

# ProcessRecord::set — O(1) mutator
ProcessRecord::set() {
    local -r _key="${1:-}"
    local -r _val="${2:-}"
    Core_PROCESS_RECORD[${_key}]="${_val}"
}

###############################################################################
# Constructor / accessor — BackupJob
###############################################################################

# BackupJob::new — reset the backup job entity
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

# BackupJob::get / ::set — O(1) accessors
BackupJob::get() {
    local -r _key="${1:-}"
    echo "${Core_BACKUP_JOB[${_key}]:-}"
}
BackupJob::set() {
    local -r _key="${1:-}"
    local -r _val="${2:-}"
    Core_BACKUP_JOB[${_key}]="${_val}"
}

###############################################################################
# Logger
###############################################################################

# Core::log — structured persistent event logging to syssentry.log
# Usage: Core::log LEVEL message [details]
Core::log() {
    local -r _level="${1:-INFO}"
    local -r _message="${2:-}"
    local -r _details="${3:-}"
    local _ts _colour _line

    _ts="$(date '+%Y-%m-%d %H:%M:%S')"
    case "${_level}" in
        DEBUG)  _colour="${Core_C_CYAN}"   ;;
        INFO)   _colour="${Core_C_GREEN}"  ;;
        WARN)   _colour="${Core_C_YELLOW}" ;;
        ERROR)  _colour="${Core_C_RED}"    ;;
        CRIT)   _colour="${Core_C_BG_RED}${Core_C_WHITE}" ;;
        *)      _colour="${Core_C_RESET}"  ;;
    esac

    # Always write to the log file (plain, no ANSI)
    if [[ -n "${Core_LOG_FILE}" && -w "$(dirname "${Core_LOG_FILE}")" ]]; then
        printf '[%s] [%s] %s%s\n' \
            "${_ts}" "${_level}" "${_message}" \
            "$([[ -n "${_details}" ]] && printf ' | %s' "${_details}" || true)" \
            >> "${Core_LOG_FILE}" 2>/dev/null || true
    fi

    # Emit to stdout only when a terminal is attached (rich UI)
    if [[ -t 1 ]]; then
        _line="[$(Core::colourise "${_level}" "${_ts}")] $(Core::colourise "${_level}" "${_level}") ${_message}"
        if [[ -n "${_details}" ]]; then
            _line+=" | ${_details}"
        fi
        printf '%b\n' "${_line}"
    fi
}

# Core::colourise — wrap text in ANSI colour by log level
Core::colourise() {
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

# Core::init — bootstrap the application: load config, build PID whitelist,
# install signal traps, initialise entities.
Core::init() {
    local _cfg_val _key _val

    # Reset entities
    SystemSnapshot::new
    ProcessRecord::new
    BackupJob::new

    # Load configuration profile into Core_CONFIG hash map (O(1) cache)
    Core::load_config

    # Build PID protection whitelist (O(1) lookups)
    Core_PROTECTED_PIDS[$$]="self"                # this script
    Core_PROTECTED_PIDS[$PPID]="parent"           # parent shell
    Core_PROTECTED_PIDS[1]="init"                 # PID 1 (init/systemd)

    # Kernel daemons (typical low PIDs) — protect against accidental kill
    for _pid in 2 3 4 5 6 7 8; do
        Core_PROTECTED_PIDS[$_pid]="kernel-daemon"
    done

    # Any user-configured protected PIDs
    _cfg_val="$(Core::config_get protected_pids "")"
    if [[ -n "${_cfg_val}" ]]; then
        IFS=',' read -ra _pids <<< "${_cfg_val}"
        for _pid in "${_pids[@]}"; do
            _pid="${_pid// /}"
            if [[ "${_pid}" =~ ^[0-9]+$ ]]; then
                Core_PROTECTED_PIDS[$_pid]="configured"
            fi
        done
    fi

    # Install signal traps (defensive mode)
    trap 'Core::cleanup; Core::handle_error $? $LINENO' ERR
    trap 'Core::cleanup; Core::handle_error $? $LINENO' EXIT
    trap 'Core::cleanup; Core::handle_error $? $LINENO' INT
    trap 'Core::cleanup; Core::handle_error $? $LINENO' TERM

    Core::log INFO "SysSentry v${Core_VERSION} initialised (pid=$$)"
}

# Core::load_config — parse syssentry.conf into Core_CONFIG hash map
# Supports KEY=value lines, inline comments (#), and blank lines.
Core::load_config() {
    local _cfg_file="${1:-${Core_CONFIG_FILE}}"
    local _line _key _val

    if [[ ! -f "${_cfg_file}" ]]; then
        Core::log WARN "Config file not found: ${_cfg_file} (using defaults)"
        return 0
    fi

    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        # Strip leading/trailing whitespace
        _line="${_line#"${_line%%[![:space:]]*}"}"
        _line="${_line%"${_line##*[![:space:]]}"}"

        # Skip blanks and comments
        [[ -z "${_line}" || "${_line}" == \#* ]] && continue

        # Parse KEY=value
        if [[ "${_line}" == *"="* ]]; then
            _key="${_line%%=*}"
            _val="${_line#*=}"
            # Trim whitespace around key/value
            _key="${_key#"${_key%%[![:space:]]*}"}"
            _key="${_key%"${_key##*[![:space:]]}"}"
            _val="${_val#"${_val%%[![:space:]]*}"}"
            _val="${_val%"${_val##*[![:space:]]}"}"
            # Strip trailing inline comment from value
            if [[ "${_val}" == *" #"* ]]; then
                _val="${_val%% #*}"
                _val="${_val%"${_val##*[![:space:]]}"}"
            fi
            Core_CONFIG[${_key}]="${_val}"
        fi
    done < "${_cfg_file}"

    Core::log DEBUG "Configuration loaded (${#Core_CONFIG[@]} entries)"
}

# Core::config_get — O(1) config accessor with optional default
# Usage: Core::config_get key default_value
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

# Core::handle_error — central error handler (no-op on success/exit code 0)
# Usage: Core::handle_error exit_code line_number
Core::handle_error() {
    local -r _code="${1:-0}"
    local -r _line="${2:-0}"

    # Guard against re-entrancy / double handling
    if [[ ${Core_EXITING} -eq 1 ]]; then
        return 0
    fi

    # Success path — clean exit
    if [[ ${_code} -eq 0 ]]; then
        Core::log INFO "SysSentry exited cleanly (code 0)"
        return 0
    fi

    Core_EXITING=1
    Core_EXIT_CODE=${_code}

    Core::log ERROR "SysSentry fatal error (exit code ${_code}) at line ${_line}"
    # Print a concise stderr message for operators
    printf '%b%s%b: %s exited with code %s at line %s\n' \
        "${Core_C_BG_RED}${Core_C_WHITE}" "FATAL" "${Core_C_RESET}" \
        "${Core_PROJECT_NAME}" "${_code}" "${_line}" >&2
}

# Core::cleanup — remove temporary files, reset guard flag
Core::cleanup() {
    local _tmp
    for _tmp in "${Core_TEMP_FILES[@]:-}"; do
        if [[ -n "${_tmp}" && -f "${_tmp}" ]]; then
            rm -f "${_tmp}" 2>/dev/null || true
        fi
    done
    Core_TEMP_FILES=()
    Core_EXITING=0
}

# Core::register_temp — register a temp file for later cleanup
Core::register_temp() {
    local -r _f="${1:-}"
    if [[ -n "${_f}" ]]; then
        Core_TEMP_FILES+=("${_f}")
    fi
}

###############################################################################
# Helpers
###############################################################################

# Core::is_root — true if running as UID 0
Core::is_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]]
}

# Core::require_root — abort if not root
Core::require_root() {
    if ! Core::is_root; then
        Core::log ERROR "Operation requires root privileges (current UID=${EUID:-unknown})"
        return 1
    fi
    return 0
}

# Core::is_integer — validate integer string
Core::is_integer() {
    local -r _s="${1:-}"
    [[ "${_s}" =~ ^-?[0-9]+$ ]]
}

# Core::is_number — validate numeric (int or float)
Core::is_number() {
    local -r _s="${1:-}"
    [[ "${_s}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]
}

# Core::msleep — non-blocking-ish sleep with fractional seconds support
Core::msleep() {
    local -r _secs="${1:-0.2}"
    sleep "${_secs}"
}

# Core::banner — print a section header
Core::banner() {
    local -r _title="${1:-SysSentry}"
    local _width=60
    if [[ -t 1 ]]; then
        _width=$(tput cols 2>/dev/null || echo 60)
        [[ "${_width}" =~ ^[0-9]+$ ]] || _width=60
    fi
    printf '\n%b=== %s ===%b\n\n' "${Core_C_BOLD}${Core_C_CYAN}" "${_title}" "${Core_C_RESET}"
}

export -f Core::init Core::log Core::config_get Core::require_root 2>/dev/null || true
