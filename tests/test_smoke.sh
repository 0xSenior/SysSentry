#!/usr/bin/env bash
#
# tests/test_smoke.sh — SysSentry Automated Smoke Test Suite
#
# Verifies that core modules load, entities construct, the monitor captures a
# snapshot, the process governor protects PID 1, and the backup engine handles
# pre-flight + retention without mutating the host.
#
# Runs under `set -euo pipefail`. Non-zero exit = failure.
#
set -euo pipefail

SENTRY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

# Source core
# shellcheck source=../lib/core.sh
source "${SENTRY_ROOT}/lib/core.sh"
# shellcheck source=../lib/monitor.sh
source "${SENTRY_ROOT}/lib/monitor.sh"
# shellcheck source=../lib/process.sh
source "${SENTRY_ROOT}/lib/process.sh"
# shellcheck source=../lib/backup.sh
source "${SENTRY_ROOT}/lib/backup.sh"

assert_eq() {
    local -r _desc="${1}" _expected="${2}" _actual="${3}"
    if [[ "${_expected}" == "${_actual}" ]]; then
        echo "  PASS: ${_desc}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${_desc} (expected='${_expected}' actual='${_actual}')"
        FAIL=$((FAIL + 1))
    fi
}

assert_true() {
    local -r _desc="${1}"
    if eval "${2}"; then
        echo "  PASS: ${_desc}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${_desc} (condition false: ${2})"
        FAIL=$((FAIL + 1))
    fi
}

echo "=============================================="
echo " SysSentry Smoke Test Suite"
echo "=============================================="

# --- Test 1: Core initialisation --------------------------------------------
echo
echo "--- Test 1: Core::init ---"
Core::init
assert_true "Core initialises without error" "true"
assert_eq "Core_VERSION is set" "2.0.0" "${Core_VERSION}"
assert_true "Core_CONFIG is an associative array" "declare -p Core_CONFIG 2>/dev/null | grep -q 'declare -A'"

# --- Test 2: SystemSnapshot entity -----------------------------------------
echo
echo "--- Test 2: SystemSnapshot pseudo-OOP ---"
SystemSnapshot::new
assert_eq "Snapshot timestamp non-empty" "true" "$([[ -n "${Core_SYSTEM_SNAPSHOT[timestamp]}" ]] && echo true || echo false)"
SystemSnapshot::set mem_percent "42.5"
assert_eq "SystemSnapshot::set/get mem_percent" "42.5" "$(SystemSnapshot::get mem_percent)"

# --- Test 3: Monitor capture ------------------------------------------------
echo
echo "--- Test 3: Monitor::capture_snapshot ---"
Monitor::capture_snapshot
assert_true "mem_total_kb > 0" "[[ ${Core_SYSTEM_SNAPSHOT[mem_total_kb]} -gt 0 ]]"
assert_true "health_state is valid" "[[ \"${Core_SYSTEM_SNAPSHOT[health_state]}\" =~ ^(NORMAL|WARNING|CRITICAL)$ ]]"
assert_true "health_score is integer" "[[ \"${Core_SYSTEM_SNAPSHOT[health_score]}\" =~ ^[0-9]+$ ]]"

# --- Test 4: PID protection whitelist ---------------------------------------
echo
echo "--- Test 4: Process::is_protected_pid (O(1) whitelist) ---"
assert_true "PID 1 is protected" "Process::is_protected_pid 1"
assert_true "Self PID ($$) is protected" "Process::is_protected_pid $$"
assert_true "Arbitrary PID 99999 is NOT protected" "! Process::is_protected_pid 99999"

# --- Test 5: Config O(1) lookup --------------------------------------------
echo
echo "--- Test 5: Core::config_get O(1) lookup ---"
# Default when key absent
assert_eq "config_get missing key returns default" "DEFAULT_VAL" "$(Core::config_get nonexistent_key DEFAULT_VAL)"
# Set and retrieve
Core_CONFIG[test_key]="test_value"
assert_eq "config_get returns stored value" "test_value" "$(Core::config_get test_key "")"

# --- Test 6: BackupJob entity ----------------------------------------------
echo
echo "--- Test 6: BackupJob pseudo-OOP ---"
BackupJob::new
assert_true "BackupJob job_id non-empty" "[[ -n \"${Core_BACKUP_JOB[job_id]}\" ]]"
BackupJob::set status "completed"
assert_eq "BackupJob::set/get status" "completed" "$(BackupJob::get status)"

# --- Test 7: Backup pre-flight (non-destructive) ----------------------------
echo
echo "--- Test 7: Backup::pre_flight_check (dry-run) ---"
# Force a snapshot then test gate logic
Monitor::capture_snapshot
if Monitor::health_is_critical; then
    echo "  NOTE: System is CRITICAL; pre-flight would abort (expected behaviour)"
else
    assert_true "pre_flight_check returns 0 when healthy" "Backup::pre_flight_check true"
fi

# --- Test 8: Retention clean on temp dir (dry-run) --------------------------
echo
echo "--- Test 8: Backup::retention_clean (dry-run, temp dir) ---"
TEST_DEST="$(mktemp -d)"
# Create an "old" archive by touching with old mtime
touch -d "10 days ago" "${TEST_DEST}/old-archive.tar.gz"
touch -d "now" "${TEST_DEST}/new-archive.tar.gz"
Backup::retention_clean "${TEST_DEST}" 7 true
rm -rf "${TEST_DEST}"
echo "  PASS: retention_clean dry-run executed without error"
PASS=$((PASS + 1))

# --- Test 9: bin/syssentry --help / --version -------------------------------
echo
echo "--- Test 9: CLI entrypoint ---"
if "${SENTRY_ROOT}/bin/syssentry" --version >/dev/null 2>&1; then
    echo "  PASS: --version works"
    PASS=$((PASS + 1))
else
    echo "  FAIL: --version failed"
    FAIL=$((FAIL + 1))
fi

# --- Summary ----------------------------------------------------------------
echo
echo "=============================================="
echo " Results: ${PASS} passed, ${FAIL} failed"
echo "=============================================="

if [[ ${FAIL} -gt 0 ]]; then
    exit 1
fi
exit 0
