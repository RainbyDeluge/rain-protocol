#!/usr/bin/env bash
# Test harness for the C2PA bridge (c2pa-embed.sh + verify.sh --c2pa).
# Skips cleanly if c2patool is absent — does not break CI without c2patool.
# Requires PKI to be initialized (bash scripts/gen-ca.sh).
# Exit: 0 if all cases PASS (or skipped), 1 if any FAIL.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
VERIFY="${SCRIPT_DIR}/verify.sh"
EMBED="${SCRIPT_DIR}/c2pa-embed.sh"

PASS=0
FAIL=0

# ── Pre-flight checks ──────────────────────────────────────────────────────────

if ! command -v c2patool &>/dev/null; then
    printf 'c2patool absent — tests C2PA ignorés (install : brew install c2patool)\n'
    printf '0 passed, 0 failed\n'
    exit 0
fi

if [[ ! -f "${REPO_ROOT}/pki/ca-cert.pem" ]]; then
    printf 'PKI absente — lancez "bash scripts/gen-ca.sh" avant les tests C2PA\n'
    printf '0 passed, 0 failed\n'
    exit 0
fi

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ── Helpers ────────────────────────────────────────────────────────────────────

pass() { printf 'PASS  %s\n' "$1"; (( PASS++ )) || true; }
fail() { printf 'FAIL  %s  (%s)\n' "$1" "$2"; (( FAIL++ )) || true; }

# ── Test fixtures ──────────────────────────────────────────────────────────────

# Minimal 8×8 RGB PNG (pure Python, no external imaging library)
TEST_PNG="${TMPDIR_TEST}/test-rain.png"
python3 - "$TEST_PNG" <<'PY'
import struct, zlib, sys

def png_chunk(tag, data):
    crc = zlib.crc32(tag + data) & 0xffffffff
    return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', crc)

w, h = 8, 8
sig  = b'\x89PNG\r\n\x1a\n'
ihdr = png_chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
row  = b'\x00' + b'\x42\x86\xc3' * w
idat = png_chunk(b'IDAT', zlib.compress(row * h, 9))
iend = png_chunk(b'IEND', b'')
open(sys.argv[1], 'wb').write(sig + ihdr + idat + iend)
PY

# Bundle A — writable copy of valid-p2-ts (for C2PA embedding)
BUNDLE_A="${TMPDIR_TEST}/bundle-a"
cp -r "${REPO_ROOT}/test-vectors/valid-p2-ts" "${BUNDLE_A}"
BUNDLE_ID_A="$(python3 -c "import json; print(json.load(open('${BUNDLE_A}/manifest.json'))['bundle_id'])")"

# Bundle B — writable copy of valid-p1 (different bundle_id, for mismatch test)
BUNDLE_B="${TMPDIR_TEST}/bundle-b"
cp -r "${REPO_ROOT}/test-vectors/valid-p1" "${BUNDLE_B}"

# C2PA output image written by c2pa-embed.sh to <bundle-dir>/<artwork-base>-c2pa.png
C2PA_IMAGE="${BUNDLE_A}/test-rain-c2pa.png"

# ── Case 1: c2pa-embed.sh produces an image with the rain.bundle assertion ────

LABEL="c2pa-embed.sh → image C2PA avec assertion rain.bundle (bundle_id concordant)"
if bash "$EMBED" "$TEST_PNG" "$BUNDLE_A" > /dev/null 2>&1 && [[ -f "$C2PA_IMAGE" ]]; then
    # Write c2patool JSON to a temp file to avoid shell-expansion issues
    C2PA_OUT_FILE="${TMPDIR_TEST}/c2pa-verify.json"
    c2patool "$C2PA_IMAGE" 2>/dev/null > "$C2PA_OUT_FILE"
    if python3 - "$C2PA_OUT_FILE" "$BUNDLE_ID_A" <<'PY'; then
import json, sys
data = json.load(open(sys.argv[1]))
expected_id = sys.argv[2]
for m in data.get("manifests", {}).values():
    for a in m.get("assertions", []):
        if a.get("label") == "rain.bundle":
            found_id = a.get("data", {}).get("bundle_id", "")
            if found_id == expected_id:
                sys.exit(0)
            print(f"  bundle_id: obtenu {found_id!r}, attendu {expected_id!r}", file=sys.stderr)
            sys.exit(1)
print("  assertion rain.bundle absente du manifest C2PA", file=sys.stderr)
sys.exit(1)
PY
        pass "$LABEL"
    else
        fail "$LABEL" "assertion rain.bundle absente ou bundle_id incorrect"
    fi
else
    fail "$LABEL" "c2pa-embed.sh a échoué ou image non produite"
fi

# ── Case 2: verify.sh --c2pa with matching image → no C2PA_MISMATCH ──────────
# The C2PA image embeds bundle_id from Bundle A; we verify Bundle A.
# C2PA assertion matches → C2PA_MISMATCH must NOT appear in warnings/errors.
# (The test bundle may DOWNGRADE for unrelated reasons such as CHAIN_UNTRUSTED
# from the test vector's cert — that is fine; only C2PA_MISMATCH would be wrong.)

LABEL="verify.sh --c2pa (concordant) → aucun C2PA_MISMATCH dans la sortie JSON"
if [[ -f "$C2PA_IMAGE" ]]; then
    VERIFY_OUT_FILE="${TMPDIR_TEST}/verify-case2.json"
    actual_rc=0
    bash "$VERIFY" --json --c2pa "$C2PA_IMAGE" "$BUNDLE_A" > "$VERIFY_OUT_FILE" 2>/dev/null || actual_rc=$?
    # Exit 1 = INVALID is the only hard failure; exit 0 or 2 are both acceptable.
    if (( actual_rc == 1 )); then
        fail "$LABEL" "verify.sh a retourné INVALID (exit 1) — inattendu"
    elif python3 - "$VERIFY_OUT_FILE" <<'PY'; then
import json, sys
data = json.load(open(sys.argv[1]))
for field in ("warnings", "errors", "downgrades"):
    for msg in data.get(field, []):
        if "C2PA_MISMATCH" in msg:
            print(f"  C2PA_MISMATCH trouvé dans {field}: {msg}", file=sys.stderr)
            sys.exit(1)
sys.exit(0)
PY
        pass "$LABEL"
    else
        fail "$LABEL" "C2PA_MISMATCH présent dans la sortie JSON (concordance attendue)"
    fi
else
    fail "$LABEL" "image C2PA absente (cas 1 échoué)"
fi

# ── Case 3: verify.sh --c2pa with mismatched bundle → DOWNGRADE ──────────────
# The C2PA image was created for Bundle A (valid-p2-ts bundle_id).
# We pass it to verify.sh while verifying Bundle B (valid-p1) — different bundle_id.
# The mismatch must trigger DOWNGRADE (C2PA_MISMATCH) → exit 2.

LABEL="verify.sh --c2pa (bundle_id mismatch) → DOWNGRADE (exit 2)"
if [[ -f "$C2PA_IMAGE" ]]; then
    actual_rc=0
    bash "$VERIFY" --json --c2pa "$C2PA_IMAGE" "$BUNDLE_B" > /dev/null 2>&1 || actual_rc=$?
    if (( actual_rc == 2 )); then
        pass "$LABEL"
    else
        fail "$LABEL" "attendu exit 2 (DOWNGRADE), obtenu exit ${actual_rc}"
    fi
else
    fail "$LABEL" "image C2PA absente (cas 1 échoué)"
fi

# ── Summary ────────────────────────────────────────────────────────────────────

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
