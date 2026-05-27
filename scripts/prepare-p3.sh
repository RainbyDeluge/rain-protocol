#!/usr/bin/env bash
# prepare-p3.sh — Prepare a bundle manifest for P3 signing (BYOK/HYOK).
#
# Usage: bash scripts/prepare-p3.sh <bundle-dir> <artist-cert-path>
#
# Unlike prepare-p2.sh, this script uses the artist-provided certificate.
# RAIN's pki/ is NOT touched: HYOK guaranteed.
#
# Canonical order: prepare-p3.sh -> [timestamp-bundle.sh] -> sign-bundle.sh
#                  (with RAIN_SIGNER_KEY=<artist-key.pem>)
#
# This script:
#   1. Copies the artist certificate into the bundle as artist-cert.pem
#   2. Computes its fingerprint and dual hashes
#   3. Updates manifest.json: proof_level=P3, signer_identity_class=self-signed,
#      signer_cert_fingerprint, files[] entry for the certificate
#
# +==========================================================================+
# |  HYOK GUARANTEE                                                           |
# |  pki/ is never read or modified by this script.                          |
# |  The artist private key is never transmitted to RAIN.                    |
# +==========================================================================+

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Arguments ─────────────────────────────────────────────────────────────────

if [[ $# -ne 2 ]]; then
    printf 'Usage: %s <bundle-dir> <artist-cert-path>\n' "$(basename "$0")" >&2
    exit 1
fi

if [[ ! -d "$1" ]]; then
    printf 'Error: bundle directory not found: %s\n' "$1" >&2
    exit 1
fi
BUNDLE_DIR="$(cd "$1" && pwd)"

ARTIST_CERT_SRC="$2"
if [[ ! -f "$ARTIST_CERT_SRC" ]]; then
    printf 'Error: artist certificate not found: %s\n' "$ARTIST_CERT_SRC" >&2
    printf '  Generate one with: bash scripts/gen-artist-key.sh <name> <dir>\n' >&2
    exit 1
fi
ARTIST_CERT_SRC="$(cd "$(dirname "$ARTIST_CERT_SRC")" && pwd)/$(basename "$ARTIST_CERT_SRC")"

# ── Guard: pki/ must not be used for P3 ──────────────────────────────────────
# HYOK safety: forbid using a cert from pki/ (the RAIN platform PKI) for P3.

PKI_DIR="${REPO_ROOT}/pki"
CERT_SRC_DIR="$(cd "$(dirname "$ARTIST_CERT_SRC")" && pwd)"
if [[ "${CERT_SRC_DIR}" == "${PKI_DIR}" || "${CERT_SRC_DIR}" == "${PKI_DIR}/"* ]]; then
    printf 'Error: artist certificate must NOT come from pki/.\n' >&2
    printf '  pki/ is reserved for the RAIN platform PKI (P2 only).\n' >&2
    printf '  Generate an artist key with: bash scripts/gen-artist-key.sh\n' >&2
    exit 1
fi

# ── Validate the certificate ──────────────────────────────────────────────────

echo "[0/4] Validating artist certificate..."
if ! openssl x509 -in "$ARTIST_CERT_SRC" -noout 2>/dev/null; then
    printf "Error: file is not a valid X.509 certificate: %s\n" "$ARTIST_CERT_SRC" >&2
    exit 1
fi
ARTIST_CN="$(openssl x509 -in "$ARTIST_CERT_SRC" -noout -subject 2>/dev/null \
    | sed 's/.*CN *= *//' | sed 's/,.*//')" || ARTIST_CN="(unknown)"
printf '  certificate : OK\n'
printf '  CN          : %s\n' "$ARTIST_CN"

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
ref = d.get('manifest_ref')
if not ref:
    sys.stderr.write(\"Error: 'manifest_ref' key missing from bundle-index.json\n\"); sys.exit(1)
print(ref)
" "${INDEX_FILE}")"

MANIFEST_FILE="${BUNDLE_DIR}/${MANIFEST_REF}"
if [[ ! -f "${MANIFEST_FILE}" ]]; then
    printf 'Error: manifest not found: %s\n' "${MANIFEST_FILE}" >&2
    exit 1
fi
echo "  manifest: ${MANIFEST_REF}"

# ── Step 2: Copy artist certificate into bundle ───────────────────────────────

echo "[2/4] Copying artist certificate into bundle..."
ARTIST_CERT_DEST="${BUNDLE_DIR}/artist-cert.pem"
cp "$ARTIST_CERT_SRC" "$ARTIST_CERT_DEST"
echo "  written: artist-cert.pem"

# ── Step 3: Compute fingerprint and hashes ────────────────────────────────────

echo "[3/4] Computing fingerprint and hashes..."

# SHA-256 fingerprint of the DER-encoded cert; strip prefix and colons -> 64 lowercase hex chars.
FINGERPRINT_RAW="$(openssl x509 -in "$ARTIST_CERT_SRC" -noout -fingerprint -sha256)"
FINGERPRINT_HEX="${FINGERPRINT_RAW#*=}"
FINGERPRINT_HEX="${FINGERPRINT_HEX//:/}"
FINGERPRINT_HEX="$(printf '%s' "${FINGERPRINT_HEX}" | tr '[:upper:]' '[:lower:]')"
echo "  fingerprint  : ${FINGERPRINT_HEX}"

CERT_HASHES="$(python3 - "${ARTIST_CERT_DEST}" <<'PY'
import hashlib, sys
data = open(sys.argv[1], 'rb').read()
print(hashlib.sha256(data).hexdigest(), hashlib.sha3_256(data).hexdigest())
PY
)"
CERT_SHA256="${CERT_HASHES%% *}"
CERT_SHA3="${CERT_HASHES##* }"
echo "  sha256   : ${CERT_SHA256}"
echo "  sha3_256 : ${CERT_SHA3}"

# ── Step 4: Update manifest to P3-ready state ────────────────────────────────

echo "[4/4] Updating manifest to P3-ready state..."
python3 - "${MANIFEST_FILE}" "${FINGERPRINT_HEX}" "${CERT_SHA256}" "${CERT_SHA3}" <<'PY'
import json, sys

manifest_path, fingerprint, cert_sha256, cert_sha3 = sys.argv[1:5]

with open(manifest_path) as f:
    manifest = json.load(f)

manifest['proof_level']             = 'P3'
manifest['signer_cert_fingerprint'] = fingerprint
manifest['signer_identity_class']   = 'self-signed'

# Drop any stale certificate entries (idempotent re-run).
manifest['files'] = [
    e for e in manifest.get('files', [])
    if e.get('role') != 'certificate'
]
manifest['files'].append({
    'name':     'artist-cert.pem',
    'sha256':   cert_sha256,
    'sha3_256': cert_sha3,
    'role':     'certificate',
})

with open(manifest_path, 'w') as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)
    f.write('\n')

print(f"  proof_level            : {manifest['proof_level']}")
print(f"  signer_identity_class  : {manifest['signer_identity_class']}")
print(f"  signer_cert_fingerprint: {fingerprint}")
print(f"  files[] count          : {len(manifest['files'])}")
PY

printf '\nManifest P3-ready: %s\n' "${BUNDLE_DIR}"
printf '\n'
printf '  IDENTITY WARNING:\n'
printf '    proof_level=P3 + signer_identity_class=self-signed means the signature\n'
printf '    is cryptographically valid, but no recognised CA attests the identity\n'
printf '    of the signer.  RAIN verifier will always show IDENTITY_UNVERIFIED.\n'
printf '\n'
printf 'Next steps:\n'
printf '  # [optional] bash scripts/timestamp-bundle.sh %s\n' "$1"
printf '  RAIN_SIGNER_KEY=<artist-key.pem> bash scripts/sign-bundle.sh %s\n' "$1"
