#!/usr/bin/env bash
# sign-bundle.sh — Sign a P2/P3-ready RAIN manifest with an Ed25519 signer key.
#
# Usage: bash scripts/sign-bundle.sh <bundle-dir>
#
# For P2 (RAIN platform key):
#   Canonical order: prepare-p2.sh → timestamp-bundle.sh → sign-bundle.sh
#
# For P3 (BYOK/HYOK artist key):
#   Canonical order: prepare-p3.sh → [timestamp-bundle.sh] → sign-bundle.sh
#   The artist key is provided via the RAIN_SIGNER_KEY environment variable:
#     RAIN_SIGNER_KEY=/path/to/artist-key.pem bash scripts/sign-bundle.sh <bundle-dir>
#
# HYOK guarantee: if RAIN_SIGNER_KEY is set, the RAIN PKI key (pki/signer-key.pem)
# is never consulted.  The artist's private key signs locally and is never transmitted.
#
# This script only signs — it does NOT modify the manifest.  The manifest must
# already be in its final signed-ready state (proof_level=P2 or P3,
# signer_cert_fingerprint set, certificate file in files[], and optionally
# manifest.tsr in files[]) so that the signature seals every declared file.
#
# Signing invariant: manifest.sig is the detached Ed25519 signature of the exact
# bytes of manifest.json as they exist at signing time.  Any post-signing change
# to manifest.json — even whitespace — invalidates the signature.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PKI_DIR="${REPO_ROOT}/pki"

# ── Argument ──────────────────────────────────────────────────────────────────

if [[ $# -ne 1 ]]; then
    printf 'Usage: %s <bundle-dir>\n' "$(basename "$0")" >&2
    exit 1
fi

# M1 — validate the argument is an existing directory before cd, so the user
# gets a clear RAIN error instead of bash's raw "cd: …: No such file or directory".
if [[ ! -d "$1" ]]; then
    printf 'Error: bundle directory not found: %s\n' "$1" >&2
    exit 1
fi
BUNDLE_DIR="$(cd "$1" && pwd)"

# ── Pre-flight: signer key ────────────────────────────────────────────────────
# RAIN_SIGNER_KEY overrides the default RAIN PKI key (used for P3 HYOK).
# HYOK principle: when RAIN_SIGNER_KEY is set, pki/ is never consulted.

echo "[0/3] Checking signer key..."
if [[ -n "${RAIN_SIGNER_KEY:-}" ]]; then
    SIGNER_KEY="${RAIN_SIGNER_KEY}"
    echo "  mode       : P3 HYOK (RAIN_SIGNER_KEY)"
    echo "  signer-key : ${SIGNER_KEY}"
    if [[ ! -f "${SIGNER_KEY}" ]]; then
        printf 'Error: RAIN_SIGNER_KEY file not found: %s\n' "${SIGNER_KEY}" >&2
        printf '  Generate an artist key with: bash scripts/gen-artist-key.sh <name> <dir>\n' >&2
        exit 1
    fi
else
    SIGNER_KEY="${PKI_DIR}/signer-key.pem"
    echo "  mode       : P2 RAIN PKI"
    echo "  signer-key : pki/signer-key.pem"
    if [[ ! -f "${SIGNER_KEY}" ]]; then
        printf 'Error: signer key not found: %s\n' "${SIGNER_KEY}" >&2
        printf 'Run: bash scripts/gen-ca.sh\n' >&2
        exit 1
    fi
fi
echo "  signer-key : OK"

# ── Step 1: Locate manifest ───────────────────────────────────────────────────

echo "[1/3] Locating manifest via bundle-index.json..."
INDEX_FILE="${BUNDLE_DIR}/bundle-index.json"
if [[ ! -f "${INDEX_FILE}" ]]; then
    printf 'Error: bundle-index.json not found in %s\n' "${BUNDLE_DIR}" >&2
    exit 1
fi

MANIFEST_REF="$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except json.JSONDecodeError as e:
    sys.stderr.write(f'Error: bundle-index.json is not valid JSON: {e}\n'); sys.exit(1)
# M2 — KeyError on d['manifest_ref'] used to show 'Error: manifest_ref' (raw
# Python repr), which is meaningless without Python context.
ref = d.get('manifest_ref')
if not ref:
    sys.stderr.write(\"Error: 'manifest_ref' key missing from bundle-index.json — \")
    sys.stderr.write('is this a valid RAIN bundle directory?\n'); sys.exit(1)
print(ref)
" "${INDEX_FILE}")"

MANIFEST_FILE="${BUNDLE_DIR}/${MANIFEST_REF}"
if [[ ! -f "${MANIFEST_FILE}" ]]; then
    printf 'Error: manifest not found: %s\n' "${MANIFEST_FILE}" >&2
    exit 1
fi
echo "  manifest: ${MANIFEST_REF}"

# ── Step 2: Verify manifest is P2-ready ──────────────────────────────────────

echo "[2/3] Checking manifest is P2-ready..."
PROOF_LEVEL="$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('proof_level', ''))
except Exception as e:
    sys.stderr.write(f'Error: {e}\n')
    sys.exit(1)
" "${MANIFEST_FILE}")"

if [[ "${PROOF_LEVEL}" != "P2" && "${PROOF_LEVEL}" != "P3" ]]; then
    printf 'Error: manifest proof_level is "%s", expected "P2" or "P3".\n' "${PROOF_LEVEL}" >&2
    printf '  For P2: bash scripts/prepare-p2.sh %s\n' "$1" >&2
    printf '  For P3: bash scripts/prepare-p3.sh %s <artist-cert.pem>\n' "$1" >&2
    exit 1
fi
echo "  proof_level : ${PROOF_LEVEL}"

# ── Step 3: Sign the manifest as-is ──────────────────────────────────────────
# Ed25519 operates on the raw message (no pre-hashing); -rawin passes bytes as-is.
# The manifest is not modified — the signature seals its exact current content.

echo "[3/3] Signing manifest with Ed25519 signer key..."
SIG_FILE="${BUNDLE_DIR}/manifest.sig"
openssl pkeyutl -sign \
    -inkey "${SIGNER_KEY}" \
    -rawin \
    -in  "${MANIFEST_FILE}" \
    -out "${SIG_FILE}"
echo "  written: manifest.sig"

# ── Summary ───────────────────────────────────────────────────────────────────

printf '\nBundle signed: %s\n' "${BUNDLE_DIR}"
printf '  %-20s sealed by manifest.sig\n' "${MANIFEST_REF}"
printf '  %-20s detached Ed25519 signature\n' "manifest.sig"
