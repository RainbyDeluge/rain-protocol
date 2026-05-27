#!/usr/bin/env bash
# Run all RAIN test suites and aggregate the results.
# Exit: 0 if every suite passes (SKIP is neutral), 1 if any suite fails.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
SUITES_FAILED=0

run_suite() {
    local script="$1"
    local label="$2"

    printf '\n══════════════════════════════════════════════════════\n'
    printf '  %s\n' "$label"
    printf '══════════════════════════════════════════════════════\n'

    local output exit_rc=0
    output="$(bash "$script" 2>&1)" || exit_rc=$?
    printf '%s\n' "$output"

    # Parse "N passed, M failed[, K skipped]" from the suite's last summary line.
    # The regex anchors on "^N passed, M failed" so it matches both variants.
    local p=0 f=0 s=0
    local summary_line
    summary_line="$(printf '%s\n' "$output" | grep -E '^[0-9]+ passed, [0-9]+ failed' | tail -1)" || true
    if [[ -n "$summary_line" ]]; then
        p="$(printf '%s\n' "$summary_line" | grep -oE '^[0-9]+')"
        # Extract "M failed" even when line ends with ", K skipped"
        f="$(printf '%s\n' "$summary_line" | grep -oE '[0-9]+ failed'  | grep -oE '^[0-9]+')"
        s="$(printf '%s\n' "$summary_line" | grep -oE '[0-9]+ skipped' | grep -oE '^[0-9]+')" || true
        # Guard against empty extraction (e.g. no match) → keep 0
        p="${p:-0}"; f="${f:-0}"; s="${s:-0}"
    fi
    TOTAL_PASS=$(( TOTAL_PASS + p ))
    TOTAL_FAIL=$(( TOTAL_FAIL + f ))
    TOTAL_SKIP=$(( TOTAL_SKIP + s ))
    if (( exit_rc != 0 )); then
        (( SUITES_FAILED++ )) || true
    fi
}

run_suite "${SCRIPT_DIR}/test-verify.sh"         "test-verify.sh         — bundles RAIN"
run_suite "${SCRIPT_DIR}/test-mals.sh"           "test-mals.sh           — capture MALS"
run_suite "${SCRIPT_DIR}/test-c2pa.sh"           "test-c2pa.sh           — bridge C2PA"
run_suite "${SCRIPT_DIR}/test-session-signer.sh" "test-session-signer.sh — session signer"
run_suite "${SCRIPT_DIR}/test-p3.sh"             "test-p3.sh             — P3 HYOK self-signed"

printf '\n══════════════════════════════════════════════════════\n'
if (( TOTAL_SKIP > 0 )); then
    printf '  TOTAL : %d passed, %d failed, %d skipped\n' \
        "$TOTAL_PASS" "$TOTAL_FAIL" "$TOTAL_SKIP"
else
    printf '  TOTAL : %d passed, %d failed\n' "$TOTAL_PASS" "$TOTAL_FAIL"
fi
printf '══════════════════════════════════════════════════════\n'

# SKIP est neutre : exit 0 seulement si aucun FAIL sur l'ensemble des suites.
(( SUITES_FAILED == 0 && TOTAL_FAIL == 0 ))
