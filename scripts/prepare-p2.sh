#!/usr/bin/env bash
# prepare-p2.sh — Prepare a bundle manifest for P2 signing (without signing it).
#
# Usage: bash scripts/prepare-p2.sh <bundle-dir>
#
# Canonical order: prepare-p2.sh → timestamp-bundle.sh → sign-bundle.sh
#
# This script finalises the manifest so it is ready to be timestamped and then
# signed.  It must run before timestamp-bundle.sh so that the timestamp covers
# a manifest that already declares the signer certificate, and before
# sign-bundle.sh so that the signature seals the complete, timestamped manifest.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PKI_DIR="${REPO_ROOT}/pki"

SIGNER_KEY="${PKI_DIR}/signer-key.pem"
SIGNER_CERT_SRC="${PKI_DIR}/signer-cert.pem"

# ── Argument ──────────────────────────────────────────────────────────────────

if [[ $# -ne 1 ]]; then
    printf 'Usage: %s <bundle-dir>\n' "$(basename "$0")" >&2
    exit 1
fi

# M1 — validate before cd (same guard as sign-bundle.sh / timestamp-bundle.sh).
if [[ ! -d "$1" ]]; then
    printf 'Error: bundle directory not found: %s\n' "$1" >&2
    exit 1
fi
BUNDLE_DIR="$(cd "$1" && pwd)"

# ── Pre-flight: PKI ───────────────────────────────────────────────────────────

echo "[0/4] Checking PKI..."
missing=false
[[ ! -f "${SIGNER_KEY}" ]]      && { printf '  missing: %s\n' "${SIGNER_KEY}";      missing=true; }
[[ ! -f "${SIGNER_CERT_SRC}" ]] && { printf '  missing: %s\n' "${SIGNER_CERT_SRC}"; missing=true; }
if [[ "${missing}" == true ]]; then
    printf 'Error: PKI not initialised. Run: bash scripts/gen-ca.sh\n' >&2
    exit 1
fi
echo "  signer-key.pem  : OK"
echo "  signer-cert.pem : OK"

# ── Step 1: Locate manifest ───────────────────────────────────────────────────

echo "[1/4] Locating manifest via bundle-index.json..."
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
# M2 — explicit message instead of raw KeyError repr.
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

# ── Step 2: Copy signer certificate into bundle ───────────────────────────────

echo "[2/4] Copying signer certificate into bundle..."
SIGNER_CERT_DEST="${BUNDLE_DIR}/signer-cert.pem"
cp "${SIGNER_CERT_SRC}" "${SIGNER_CERT_DEST}"
echo "  written: signer-cert.pem"

# ── Step 3: Compute fingerprint and file hashes ───────────────────────────────

echo "[3/4] Computing fingerprint and hashes..."

# SHA-256 fingerprint of the DER-encoded cert; strip prefix and colons → 64 lowercase hex chars.
FINGERPRINT_RAW="$(openssl x509 -in "${SIGNER_CERT_SRC}" -noout -fingerprint -sha256)"
FINGERPRINT_HEX="${FINGERPRINT_RAW#*=}"
FINGERPRINT_HEX="${FINGERPRINT_HEX//:/}"
FINGERPRINT_HEX="$(printf '%s' "${FINGERPRINT_HEX}" | tr '[:upper:]' '[:lower:]')"
echo "  fingerprint  : ${FINGERPRINT_HEX}"

CERT_HASHES="$(python3 - "${SIGNER_CERT_DEST}" <<'PY'
import hashlib, sys
data = open(sys.argv[1], 'rb').read()
print(hashlib.sha256(data).hexdigest(), hashlib.sha3_256(data).hexdigest())
PY
)"
CERT_SHA256="${CERT_HASHES%% *}"
CERT_SHA3="${CERT_HASHES##* }"
echo "  signer-cert sha256   : ${CERT_SHA256}"
echo "  signer-cert sha3_256 : ${CERT_SHA3}"

# ── Step 4: Update manifest to P2-ready state ─────────────────────────────────

echo "[4/4] Updating manifest to P2-ready state..."
python3 - "${MANIFEST_FILE}" "${FINGERPRINT_HEX}" "${CERT_SHA256}" "${CERT_SHA3}" <<'PY'
import json, sys

manifest_path, fingerprint, cert_sha256, cert_sha3 = sys.argv[1:5]

with open(manifest_path) as f:
    manifest = json.load(f)

manifest['proof_level'] = 'P2'
manifest['signer_cert_fingerprint'] = fingerprint

# Drop any stale certificate entries (idempotent re-run).
manifest['files'] = [
    e for e in manifest.get('files', [])
    if e.get('role') != 'certificate'
]
manifest['files'].append({
    'name':     'signer-cert.pem',
    'sha256':   cert_sha256,
    'sha3_256': cert_sha3,
    'role':     'certificate',
})

with open(manifest_path, 'w') as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)
    f.write('\n')

print(f"  proof_level            : {manifest['proof_level']}")
print(f"  signer_cert_fingerprint: {fingerprint}")
print(f"  files[] count          : {len(manifest['files'])}")
PY

printf '\nManifest is P2-ready: %s\n' "${BUNDLE_DIR}"
printf 'Next steps:\n'
printf '  bash scripts/timestamp-bundle.sh %s\n' "$1"
printf '  bash scripts/sign-bundle.sh      %s\n' "$1"
