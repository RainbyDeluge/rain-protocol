#!/usr/bin/env bash
# sign-bundle.sh — Sign a RAIN manifest and upgrade a bundle to P2
#
# Usage: bash scripts/sign-bundle.sh <bundle-dir>
#
# Ordering note (egg-and-chicken constraint):
#   The manifest must be fully finalised *before* signing because the Ed25519
#   signature covers the exact bytes of the manifest as verifiers will read it.
#   manifest.sig cannot be listed in files[]: its hash would change the manifest,
#   which would change the signature — a circular dependency.
#   Only signer-cert.pem appears in files[]; manifest.sig is the detached
#   signature of the manifest itself and stands outside the files[] inventory.
#   Correct order: finalise manifest → sign → place manifest.sig in bundle.

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

BUNDLE_DIR="$(cd "$1" && pwd)"

# ── Pre-flight: PKI ───────────────────────────────────────────────────────────

echo "[0/5] Checking PKI..."
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

echo "[1/5] Locating manifest via bundle-index.json..."
INDEX_FILE="${BUNDLE_DIR}/bundle-index.json"
if [[ ! -f "${INDEX_FILE}" ]]; then
    printf 'Error: bundle-index.json not found in %s\n' "${BUNDLE_DIR}" >&2
    exit 1
fi

MANIFEST_REF="$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d['manifest_ref'])
except (KeyError, Exception) as e:
    sys.stderr.write(f'Error: {e}\n')
    sys.exit(1)
" "${INDEX_FILE}")"

MANIFEST_FILE="${BUNDLE_DIR}/${MANIFEST_REF}"
if [[ ! -f "${MANIFEST_FILE}" ]]; then
    printf 'Error: manifest not found: %s\n' "${MANIFEST_FILE}" >&2
    exit 1
fi
echo "  manifest: ${MANIFEST_REF}"

# ── Step 2: Copy signer certificate into bundle ───────────────────────────────

echo "[2/5] Copying signer certificate into bundle..."
SIGNER_CERT_DEST="${BUNDLE_DIR}/signer-cert.pem"
cp "${SIGNER_CERT_SRC}" "${SIGNER_CERT_DEST}"
echo "  written: signer-cert.pem"

# ── Step 3: Compute fingerprint and file hashes ───────────────────────────────

echo "[3/5] Computing fingerprint and hashes..."

# SHA-256 fingerprint of the DER-encoded cert; strip prefix and colons → 64 lowercase hex chars.
FINGERPRINT_RAW="$(openssl x509 -in "${SIGNER_CERT_SRC}" -noout -fingerprint -sha256)"
FINGERPRINT_HEX="${FINGERPRINT_RAW#*=}"          # strip "sha256 Fingerprint="
FINGERPRINT_HEX="${FINGERPRINT_HEX//:/}"          # strip colons
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

# ── Step 4: Finalise manifest (must happen BEFORE signing — see header note) ──

echo "[4/5] Updating manifest to P2..."
python3 - "${MANIFEST_FILE}" "${FINGERPRINT_HEX}" "${CERT_SHA256}" "${CERT_SHA3}" <<'PY'
import json, sys

manifest_path, fingerprint, cert_sha256, cert_sha3 = sys.argv[1:5]

with open(manifest_path) as f:
    manifest = json.load(f)

manifest['proof_level'] = 'P2'
manifest['signer_cert_fingerprint'] = fingerprint

# Drop any stale certificate/signature entries so the script is idempotent.
manifest['files'] = [
    e for e in manifest.get('files', [])
    if e.get('role') not in ('certificate', 'signature')
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

# ── Step 5: Sign the finalised manifest ───────────────────────────────────────
# Ed25519 operates on the raw message (no pre-hashing); -rawin passes bytes as-is.

echo "[5/5] Signing manifest with Ed25519 signer key..."
SIG_FILE="${BUNDLE_DIR}/manifest.sig"
openssl pkeyutl -sign \
    -inkey "${SIGNER_KEY}" \
    -rawin \
    -in  "${MANIFEST_FILE}" \
    -out "${SIG_FILE}"
echo "  written: manifest.sig"

# ── Summary ───────────────────────────────────────────────────────────────────

printf '\nBundle upgraded to P2: %s\n' "${BUNDLE_DIR}"
printf '  %-20s proof_level=P2, signer_cert_fingerprint set\n' "${MANIFEST_REF}"
printf '  %-20s certificate (listed in files[])\n' "signer-cert.pem"
printf '  %-20s detached Ed25519 signature (not in files[])\n' "manifest.sig"
