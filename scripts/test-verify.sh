#!/usr/bin/env bash
# Test harness for scripts/verify.sh — checks exit codes against expected values.
# Exit: 0 if all cases PASS, 1 if any FAIL.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="${SCRIPT_DIR}/verify.sh"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0

run_case() {
    local bundle="$1"
    local expected="$2"
    local label="$3"

    local actual=0
    bash "$VERIFY" --json "${REPO_ROOT}/${bundle}" > /dev/null 2>&1 || actual=$?

    if (( actual == expected )); then
        printf 'PASS  %s  (exit %d)\n' "$label" "$actual"
        (( PASS++ )) || true
    else
        printf 'FAIL  %s  (expected %d, got %d)\n' "$label" "$expected" "$actual"
        (( FAIL++ )) || true
    fi
}

run_case_abs() {
    local path="$1"
    local expected="$2"
    local label="$3"

    local actual=0
    bash "$VERIFY" --json "$path" > /dev/null 2>&1 || actual=$?

    if (( actual == expected )); then
        printf 'PASS  %s  (exit %d)\n' "$label" "$actual"
        (( PASS++ )) || true
    else
        printf 'FAIL  %s  (expected %d, got %d)\n' "$label" "$expected" "$actual"
        (( FAIL++ )) || true
    fi
}

run_case "test-vectors/valid-p1"           0  "valid-p1           → VALID"
run_case "test-vectors/valid-p2-ts"        0  "valid-p2-ts        → VALID (P2 + timestamp)"
run_case "test-vectors/tampered-hash"      1  "tampered-hash      → INVALID"
run_case "test-vectors/downgrade-p2-nosig" 2  "downgrade-p2-nosig → DOWNGRADE"
run_case "test-vectors/tampered-sig"       1  "tampered-sig       → INVALID (SIGNATURE_INVALID)"

# ── Zip equivalence: valid-p2-ts directory → .zip → same result ───────────────
_TMP_ZIP_DIR="$(mktemp -d)"
_TMP_ZIP="${_TMP_ZIP_DIR}/valid-p2-ts.zip"
python3 - "${REPO_ROOT}/test-vectors/valid-p2-ts" "$_TMP_ZIP" <<'PY'
import zipfile, sys, pathlib
bundle = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(sys.argv[2], 'w', zipfile.ZIP_DEFLATED) as z:
    for f in sorted(bundle.iterdir()):
        if f.is_file():
            z.write(f, f.name)
PY
run_case_abs "$_TMP_ZIP" 0 "valid-p2-ts.zip    → VALID (zip ≡ dossier)"
rm -rf "$_TMP_ZIP_DIR"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
