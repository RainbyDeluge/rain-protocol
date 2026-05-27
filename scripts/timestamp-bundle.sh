#!/usr/bin/env bash
# timestamp-bundle.sh — Obtain an RFC 3161 timestamp and integrate it into the manifest.
#
# Usage: bash scripts/timestamp-bundle.sh <bundle-dir>
#
# Canonical order: prepare-p2.sh → timestamp-bundle.sh → sign-bundle.sh
#
# Circular-dependency solution:
#   openssl ts -query -data <file> hashes the file and seals that hash.
#   If we used -data manifest.json and then added the TSR entry to files[], we
#   would modify manifest.json, making the sealed hash stale and verification
#   impossible against the current file.
#
#   Instead we use -digest: we compute SHA-256 of the manifest *before* any
#   modification ("anchor digest"), pass that hex digest directly to openssl
#   ts -query, and embed the anchor digest into manifest.json itself as
#   timestamp_anchor_sha256 — the Single Source of Truth for timestamp verification.
#
#   SSOT principle: every piece of information required for verification must
#   live either in the signed object (manifest.json) or in an explicitly
#   verified external authority (TSA).  The anchor digest is attested by the
#   TSA token AND sealed by the Ed25519 signature that follows — it is never
#   stored in the unsigned bundle-index.json.
#
#   Verification later:
#     DIGEST=$(jq -r .timestamp_anchor_sha256 manifest.json)
#     openssl ts -verify -digest $DIGEST -sha256 -in manifest.tsr -CAfile …

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Default TSA: DigiCert (public, no rate limits). Override with RAIN_TSA_URL env var.
# For freetsa: RAIN_TSA_URL=https://freetsa.org/tsr bash scripts/timestamp-bundle.sh <dir>
TSA_URL="${RAIN_TSA_URL:-http://timestamp.digicert.com}"

# Select TSA cert bundle based on URL
if [[ "$TSA_URL" == *"freetsa"* ]]; then
    TSA_CA="${REPO_ROOT}/tsa/freetsa-cacert.pem"
    TSA_CERT="${REPO_ROOT}/tsa/freetsa-tsa.crt"
    TSA_CERT_NAMES=("freetsa-cacert.pem" "freetsa-tsa.crt")
    TSA_LABEL="freetsa.org"
else
    TSA_CA="${REPO_ROOT}/tsa/digicert-assured-root.pem"
    TSA_CERT=""    # DigiCert embeds full chain in TSR; only root anchor needed
    TSA_CERT_NAMES=("digicert-assured-root.pem")
    TSA_LABEL="timestamp.digicert.com"
fi

# ── Argument ──────────────────────────────────────────────────────────────────

if [[ $# -ne 1 ]]; then
    printf 'Usage: %s <bundle-dir>\n' "$(basename "$0")" >&2
    exit 1
fi

# M1 — validate before cd (same guard as prepare-p2.sh / sign-bundle.sh).
if [[ ! -d "$1" ]]; then
    printf 'Error: bundle directory not found: %s\n' "$1" >&2
    exit 1
fi
BUNDLE_DIR="$(cd "$1" && pwd)"

# ── Pre-flight: TSA certificates ──────────────────────────────────────────────

echo "[0/5] Checking TSA certificates (TSA: ${TSA_LABEL})..."
missing_tsa=false
[[ ! -f "${TSA_CA}" ]] && { printf '  missing: %s\n' "${TSA_CA}"; missing_tsa=true; }
[[ -n "${TSA_CERT}" && ! -f "${TSA_CERT}" ]] && { printf '  missing: %s\n' "${TSA_CERT}"; missing_tsa=true; }
if [[ "${missing_tsa}" == true ]]; then
    printf 'Error: TSA certificates not found. Run: bash scripts/get-tsa-cert.sh\n' >&2
    exit 1
fi
for _cert_name in "${TSA_CERT_NAMES[@]}"; do
    echo "  ${_cert_name} : OK"
done

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

# Guard: timestamping modifies manifest.json, which would break an existing signature.
if [[ -f "${BUNDLE_DIR}/manifest.sig" ]]; then
    printf 'Error: manifest.sig already exists — the bundle is already signed.\n' >&2
    printf 'Timestamping after signing would invalidate the Ed25519 signature.\n' >&2
    printf 'Canonical order: prepare-p2.sh → timestamp-bundle.sh → sign-bundle.sh\n' >&2
    exit 1
fi

TSQ_FILE="${BUNDLE_DIR}/manifest.tsq"
TSR_FILE="${BUNDLE_DIR}/manifest.tsr"

# ── Step 2: Hash manifest (pre-modification) and create TSQ ──────────────────
# This hash is the "anchor digest" — the TSA seals it, and it will be embedded
# into manifest.json as timestamp_anchor_sha256 (attested historical state,
# non-recomputable from the final manifest, whose verity is guaranteed by the
# TSA attestation and the Ed25519 signature that follows).

echo "[2/5] Hashing manifest and creating timestamp request (TSQ)..."
MANIFEST_HASH="$(python3 -c "
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest())
" "${MANIFEST_FILE}")"
echo "  manifest sha256 (pre-TSR) : ${MANIFEST_HASH}"

openssl ts -query \
    -digest "${MANIFEST_HASH}" \
    -sha256 \
    -cert \
    -out "${TSQ_FILE}"
echo "  written: manifest.tsq"

# ── Step 3: Send request to TSA ──────────────────────────────────────────────

echo "[3/5] Sending TSQ to ${TSA_LABEL}..."
HTTP_STATUS="$(curl --silent --show-error \
    --write-out '%{http_code}' \
    --request POST "${TSA_URL}" \
    --header 'Content-Type: application/timestamp-query' \
    --header 'User-Agent: RAIN/0.1' \
    --data-binary "@${TSQ_FILE}" \
    --output "${TSR_FILE}")"

if [[ "${HTTP_STATUS}" != "200" ]]; then
    printf 'Error: %s returned HTTP %s\n' "${TSA_LABEL}" "${HTTP_STATUS}" >&2
    printf 'Check network connectivity and try again.\n' >&2
    rm -f "${TSQ_FILE}" "${TSR_FILE}"
    exit 1
fi

if [[ ! -s "${TSR_FILE}" ]]; then
    printf 'Error: received empty response from TSA\n' >&2
    rm -f "${TSQ_FILE}" "${TSR_FILE}"
    exit 1
fi

echo "  received: manifest.tsr ($(wc -c < "${TSR_FILE}" | tr -d ' ') bytes)"
rm -f "${TSQ_FILE}"

# ── Step 4: Verify the token (using the same pre-modification digest) ─────────

echo "[4/5] Verifying timestamp token..."
_verify_cmd=(openssl ts -verify -digest "${MANIFEST_HASH}" -sha256 -in "${TSR_FILE}" -CAfile "${TSA_CA}")
[[ -n "${TSA_CERT}" ]] && _verify_cmd+=(-untrusted "${TSA_CERT}")
if ! "${_verify_cmd[@]}" > /dev/null 2>&1; then
    # M3 — add actionable diagnostics: the bare "verification failed" gave no
    # indication of cause (wrong cert, wrong URL, corrupt token, network issue).
    printf 'Error: timestamp token verification failed.\n' >&2
    printf '  Possible causes:\n' >&2
    printf '    1. TSA certificate mismatch — current TSA: %s\n' "${TSA_LABEL}" >&2
    printf '       Re-fetch certs: bash scripts/get-tsa-cert.sh\n' >&2
    printf '    2. Wrong TSA URL — override: RAIN_TSA_URL=https://freetsa.org/tsr bash scripts/timestamp-bundle.sh %s\n' "$1" >&2
    printf '    3. Corrupt TSR — delete %s and retry\n' "${TSR_FILE}" >&2
    exit 1
fi
echo "  Token verified OK"
TIMESTAMP_LINE="$(openssl ts -reply -in "${TSR_FILE}" -text 2>/dev/null | grep 'Time stamp' || true)"
echo "  ${TIMESTAMP_LINE}"

# ── Step 5: Add manifest.tsr to manifest files[] and embed anchor digest ──────
# manifest.json is modified here: the TSR entry is added to files[] AND the
# anchor digest is stored as timestamp_anchor_sha256 (top-level field).
# The TSR is still verifiable because it seals MANIFEST_HASH (pre-modification).
# timestamp_anchor_sha256 is attested historical data: it represents the state
# of the manifest before the TSR entry was inserted, is non-recomputable from
# the final manifest, and its verity is guaranteed by both the TSA attestation
# and the Ed25519 signature that sign-bundle.sh applies next.
# bundle-index.json is NOT modified — it carries no timestamp data.

echo "[5/5] Adding manifest.tsr to manifest files[] and embedding anchor digest..."

TSR_HASHES="$(python3 - "${TSR_FILE}" <<'PY'
import hashlib, sys
data = open(sys.argv[1], 'rb').read()
print(hashlib.sha256(data).hexdigest(), hashlib.sha3_256(data).hexdigest())
PY
)"
TSR_SHA256="${TSR_HASHES%% *}"
TSR_SHA3="${TSR_HASHES##* }"

python3 - "${MANIFEST_FILE}" "${TSR_SHA256}" "${TSR_SHA3}" "${MANIFEST_HASH}" <<'PY'
import json, sys
manifest_path, tsr_sha256, tsr_sha3, anchor_digest = sys.argv[1:5]
with open(manifest_path) as f:
    manifest = json.load(f)
manifest['files'] = [e for e in manifest.get('files', []) if e.get('role') != 'timestamp']
manifest['files'].append({'name': 'manifest.tsr', 'sha256': tsr_sha256, 'sha3_256': tsr_sha3, 'role': 'timestamp'})
manifest['timestamp_anchor_sha256'] = anchor_digest
with open(manifest_path, 'w') as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)
    f.write('\n')
print(f"  manifest.tsr added to files[] (role=timestamp)")
print(f"  timestamp_anchor_sha256 embedded in manifest")
print(f"  files[] count: {len(manifest['files'])}")
PY

# ── Summary ───────────────────────────────────────────────────────────────────

printf '\nBundle timestamped: %s\n' "${BUNDLE_DIR}"
printf '  manifest.tsr           — RFC 3161 token in manifest files[] (role=timestamp)\n'
printf '  manifest.json          — timestamp_anchor_sha256 embedded (SSOT for verification)\n'
printf '  bundle-index.json      — unchanged (no timestamp data)\n'
printf '\nTo verify the timestamp later:\n'
printf '  DIGEST=$(python3 -c "import json; print(json.load(open('"'"'manifest.json'"'"')).get('"'"'timestamp_anchor_sha256'"'"', '"'"''"'"'))")\n'
if [[ "$TSA_URL" == *"freetsa"* ]]; then
    printf '  openssl ts -verify -digest $DIGEST -sha256 \\\n'
    printf '    -in %s/manifest.tsr \\\n' "${BUNDLE_DIR}"
    printf '    -CAfile tsa/freetsa-cacert.pem -untrusted tsa/freetsa-tsa.crt\n'
else
    printf '  openssl ts -verify -digest $DIGEST -sha256 \\\n'
    printf '    -in %s/manifest.tsr \\\n' "${BUNDLE_DIR}"
    printf '    -CAfile tsa/digicert-assured-root.pem\n'
fi
printf '\nNext step:\n'
printf '  bash scripts/sign-bundle.sh %s\n' "$1"
