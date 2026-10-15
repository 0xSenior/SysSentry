#!/usr/bin/env bash
#
# lib/backup.sh — SysSentry Backup Engine Module
#
# Performs timestamped incremental/full backups using tar with gzip
# compression, guarded by a pre-flight safety gate that aborts when system
# health is CRITICAL (to prevent server starvation).
#
# Incremental diffing uses tar -g snapshot metadata (O(N) by file metadata,
# not full-content hashing). Retention cleaning prunes archives older than a
# configurable window in O(N) via a single find pass.
#
# Namespace: Backup:: (public), Backup::_* (private)

# shellcheck disable=SC2154
set -euo pipefail

###############################################################################
# Backup::pre_flight_check
#
# Aborts backup if system health is CRITICAL. Captures a fresh snapshot for
# the gate decision.
#
# @param dry_run "true" to simulate without side effects
# @return Core_EXIT_SUCCESS if safe to proceed, Core_ERR_RESOURCE_PRESSURE if CRITICAL
###############################################################################
Backup::pre_flight_check() {
    local -r _dry_run="${1:-false}"

    Monitor::capture_snapshot

    if Monitor::health_is_critical; then
        Core::log CRIT "Backup pre-flight ABORTED: system health is CRITICAL"
        Core::log CRIT "  mem=${Core_SYSTEM_SNAPSHOT[mem_percent]}% cpu=${Core_SYSTEM_SNAPSHOT[cpu_percent]}% io=${Core_SYSTEM_SNAPSHOT[io_wait_percent]}% load=${Core_SYSTEM_SNAPSHOT[load_1min]}"

        if [[ "${_dry_run}" == "true" ]]; then
            printf '%b[DRY-RUN]%b Would abort backup (CRITICAL health)%b\n' "${Core_C_YELLOW}" "${Core_C_RESET}" "${Core_C_RESET}"
        fi

        return "${Core_ERR_RESOURCE_PRESSURE}"
    fi

    Core::log INFO "Backup pre-flight PASSED (health=${Core_SYSTEM_SNAPSHOT[health_state]})"

    if [[ "${_dry_run}" == "true" ]]; then
        printf '%b[DRY-RUN]%b Backup pre-flight would PASS (health=%s)%b\n' "${Core_C_GREEN}" "${Core_C_RESET}" "${Core_SYSTEM_SNAPSHOT[health_state]}" "${Core_C_RESET}"
    fi

    return "${Core_EXIT_SUCCESS}"
}

###############################################################################
# Backup::run_backup
#
# Creates a timestamped gzip-compressed tar archive. Full backups omit the -g
# snapshot (true full). Incremental backups use tar -g for O(N) metadata-based
# diffing. Creates a find -newer anchor for future O(N) diff verification.
#
# @param source_dir source directory to archive
# @param dest_dir destination directory for the archive
# @param backup_type full|incremental (default: full)
# @param dry_run "true" to simulate without side effects
# @return Core_EXIT_SUCCESS on success, Core_ERR_BACKUP on tar failure
###############################################################################
Backup::run_backup() {
    local -r _source="${1:-}"
    local -r _dest="${2:-}"
    local -r _type="${3:-full}"
    local -r _dry_run="${4:-false}"

    if [[ -z "${_source}" || -z "${_dest}" ]]; then
        Core::log ERROR "Backup::run_backup requires <source> and <destination>"
        return "${Core_ERR_USAGE}"
    fi

    if [[ ! -d "${_source}" ]]; then
        Core::log ERROR "Source directory does not exist: ${_source}"
        return "${Core_ERR_IO}"
    fi

    if [[ ! -d "${_dest}" ]]; then
        Core::log WARN "Destination directory missing; creating: ${_dest}"
        if [[ "${_dry_run}" == "true" ]]; then
            printf '%b[DRY-RUN]%b Would create %s\n' "${Core_C_YELLOW}" "${Core_C_RESET}" "${_dest}"
        else
            mkdir -p "${_dest}" 2>/dev/null || {
                Core::log ERROR "Cannot create destination: ${_dest}"
                return "${Core_ERR_IO}"
            }
        fi
    fi

    BackupJob::new
    BackupJob::set source "${_source}"
    BackupJob::set destination "${_dest}"
    BackupJob::set type "${_type}"
    BackupJob::set status "running"

    local -r _archive_name="syssentry-$(date '+%Y%m%d%H%M%S')-${_type}.tar.gz"
    local -r _archive_path="${_dest}/${_archive_name}"
    local -r _snapshot_file="${_dest}/${_archive_name%.tar.gz}.snar"

    BackupJob::set archive_name "${_archive_name}"
    BackupJob::set snapshot_file "${_snapshot_file}"

    Core::log INFO "Starting ${_type} backup: ${_source} -> ${_archive_path}"

    if [[ "${_dry_run}" == "true" ]]; then
        printf '%b[DRY-RUN]%b Would %sbackup %s -> %s\n' \
            "${Core_C_YELLOW}" "${Core_C_RESET}" "${_type}" "${_source}" "${_archive_path}"
        BackupJob::set status "dry-run"
        BackupJob::set duration_sec "0"
        return "${Core_EXIT_SUCCESS}"
    fi

    local -i _start _end _duration
    _start="$(date +%s)"

    local -i _rc=0
    if [[ "${_type}" == "incremental" ]]; then
        Core::log DEBUG "Using incremental tar snapshot: ${_snapshot_file}"
        if ! tar -czf "${_archive_path}" -g "${_snapshot_file}" -C "$(dirname "${_source}")" "$(basename "${_source}")" 2>/dev/null; then
            _rc=$?
            Core::log ERROR "Incremental tar failed (rc=${_rc})"
            BackupJob::set status "failed"
            BackupJob::set error_message "tar rc=${_rc}"
            return "${Core_ERR_BACKUP}"
        fi
    else
        rm -f "${_snapshot_file}" 2>/dev/null || true
        if ! tar -czf "${_archive_path}" -C "$(dirname "${_source}")" "$(basename "${_source}")" 2>/dev/null; then
            _rc=$?
            Core::log ERROR "Full tar failed (rc=${_rc})"
            BackupJob::set status "failed"
            BackupJob::set error_message "tar rc=${_rc}"
            return "${Core_ERR_BACKUP}"
        fi
    fi

    _end="$(date +%s)"
    _duration=$(( _end - _start ))

    local _bytes=0
    if [[ -f "${_archive_path}" ]]; then
        _bytes="$(stat -c '%s' "${_archive_path}" 2>/dev/null || echo 0)"
    fi

    BackupJob::set bytes "${_bytes}"
    BackupJob::set duration_sec "${_duration}"
    BackupJob::set status "completed"

    touch "${_snapshot_file}" 2>/dev/null || true

    Core::log INFO "${_type} backup completed in ${_duration}s (${_bytes} bytes) -> ${_archive_name}"

    printf '%b%s%b backup complete: %s (%d bytes, %ds)\n' \
        "${Core_C_GREEN}${Core_C_BOLD}" "${_type^^}" "${Core_C_RESET}" \
        "${_archive_name}" "${_bytes}" "${_duration}"

    return "${Core_EXIT_SUCCESS}"
}

###############################################################################
# Backup::retention_clean
#
# Prunes backup archives older than RETENTION_DAYS in O(N) via a single find
# pass. Also removes orphaned .snar snapshot files. Safe on symlinks (find
# -type f excludes them).
#
# @param dest_dir backup destination directory
# @param retention_days maximum age in days (default from config)
# @param dry_run "true" to simulate without side effects
# @return Core_EXIT_SUCCESS
###############################################################################
Backup::retention_clean() {
    local -r _dest="${1:-}"
    local -r _days="${2:-${Core_CONFIG[retention_days]:-7}}"
    local -r _dry_run="${3:-false}"

    if [[ -z "${_dest}" || ! -d "${_dest}" ]]; then
        Core::log WARN "Retention clean: destination missing: ${_dest}"
        return "${Core_EXIT_SUCCESS}"
    fi

    Core::log INFO "Running retention cleanup (older than ${_days} days) in ${_dest}"

    if [[ "${_dry_run}" == "true" ]]; then
        printf '%b[DRY-RUN]%b Would prune backups older than %d days in %s\n' \
            "${Core_C_YELLOW}" "${Core_C_RESET}" "${_days}" "${_dest}"
    fi

    local _count=0 _freed=0 _f _sz
    while IFS= read -r _f || [[ -n "${_f}" ]]; do
        [[ -z "${_f}" ]] && continue
        _count=$(( _count + 1 ))
        _sz="$(stat -c '%s' "${_f}" 2>/dev/null || echo 0)"
        _freed=$(( _freed + _sz ))

        if [[ "${_dry_run}" == "true" ]]; then
            printf '  [DRY-RUN] would remove: %s (%d bytes)\n' "${_f}" "${_sz}"
        else
            rm -f "${_f}" 2>/dev/null && Core::log DEBUG "Pruned: ${_f}"
            rm -f "${_f%.tar.gz}.snar" 2>/dev/null || true
        fi
    done < <(find "${_dest}" -maxdepth 1 -type f -name '*.tar.gz' -mtime "+${_days}" -print 2>/dev/null)

    Core::log INFO "Retention clean: ${_count} archive(s) pruned, ~${_freed} bytes freed"

    if [[ "${_dry_run}" == "true" ]]; then
        printf '%b[DRY-RUN]%b Would prune %d archive(s) (~%d bytes)\n' \
            "${Core_C_YELLOW}" "${Core_C_RESET}" "${_count}" "${_freed}"
    else
        printf '%bRetention clean:%b %d archive(s) pruned, ~%d bytes freed\n' \
            "${Core_C_GREEN}" "${Core_C_RESET}" "${_count}" "${_freed}"
    fi

    return "${Core_EXIT_SUCCESS}"
}

###############################################################################
# Backup::list_backups
#
# Enumerates existing .tar.gz archives in the destination directory with size
# and age information.
#
# @param dest_dir backup destination directory (default from config)
# @return Core_EXIT_SUCCESS
###############################################################################
Backup::list_backups() {
    local -r _dest="${1:-${Core_CONFIG[backup_dest]:-/var/backups/syssentry}}"

    if [[ ! -d "${_dest}" ]]; then
        Core::log WARN "Backup destination does not exist: ${_dest}"
        return "${Core_EXIT_SUCCESS}"
    fi

    local _f _count=0 _sz _mtime _now _diff _age_days

    printf '%bExisting backups in %s:%b\n' "${Core_C_CYAN}" "${_dest}" "${Core_C_RESET}"
    printf '  %-30s %-12s %-10s\n' "ARCHIVE" "SIZE(BYTES)" "AGE(DAYS)"
    printf '  %-30s %-12s %-10s\n' "-------" "----------" "----------"

    while IFS= read -r _f || [[ -n "${_f}" ]]; do
        [[ -z "${_f}" ]] && continue
        _count=$(( _count + 1 ))

        _sz="$(stat -c '%s' "${_f}" 2>/dev/null || echo 0)"
        _mtime="$(stat -c '%Y' "${_f}" 2>/dev/null || echo 0)"
        _now="$(date +%s)"
        _diff=$(( (_now - _mtime) / 86400 ))

        printf '  %-30s %-12s %-10s\n' "$(basename "${_f}")" "${_sz}" "${_diff}"
    done < <(find "${_dest}" -maxdepth 1 -type f -name '*.tar.gz' -print 2>/dev/null | sort -r)

    if [[ ${_count} -eq 0 ]]; then
        printf '  (none)\n'
    fi
    printf '\n'

    return "${Core_EXIT_SUCCESS}"
}
