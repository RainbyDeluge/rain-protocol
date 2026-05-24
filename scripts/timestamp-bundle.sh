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
#   modification, pass that hex digest directly to openssl ts -query, and store
#   the digest in bundle-index.json as timestamp_data_sha256.  Adding the TSR
#   entry to files[] then modifying manifest.json is safe — the TSR seals the
#   pre-modification hash, not the file path.
#
#   Verification later:
#     DIGEST=$(jq -r .timestamp_data_sha256 bundle-index.json)
#     openssl ts -verify -digest $DIGEST -sha256 -in manifest.tsr -CAfile …

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TSA_URL="https://freetsa.org/tsr"
TSA_CA="${REPO_ROOT}/tsa/freetsa-cacert.pem"
TSA_CERT="${REPO_ROOT}/tsa/freetsa-tsa.crt"

# ── Argument ──────────────────────────────────────────────────────────────────

if [[ $# -ne 1 ]]; then
    printf 'Usage: %s <bundle-dir>\n' "$(basename "$0")" >&2
    exit 1
fi

BUNDLE_DIR="$(cd "$1" && pwd)"

# ── Pre-flight: TSA certificates ──────────────────────────────────────────────

echo "[0/5] Checking TSA certificates..."
missing_tsa=false
[[ ! -f "${TSA_CA}" ]]   && { printf '  missing: %s\n' "${TSA_CA}";   missing_tsa=true; }
[[ ! -f "${TSA_CERT}" ]] && { printf '  missing: %s\n' "${TSA_CERT}"; missing_tsa=true; }
if [[ "${missing_tsa}" == true ]]; then
    printf 'Error: TSA certificates not found. Run: bash scripts/get-tsa-cert.sh\n' >&2
    exit 1
fi
echo "  freetsa-cacert.pem : OK"
echo "  freetsa-tsa.crt    : OK"

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
    sys.stderr.write(f'Error: {e}\n'); sys.exit(1)
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
# The TSA seals this hash, not the file path.  We store it so verifiers can
# reproduce the exact input to openssl ts -verify without needing a pre-TSR copy.

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

# ── Step 3: Send request to freetsa.org ──────────────────────────────────────

echo "[3/5] Sending TSQ to freetsa.org..."
HTTP_STATUS="$(curl --silent --show-error \
    --write-out '%{http_code}' \
    --request POST "${TSA_URL}" \
    --header 'Content-Type: application/timestamp-query' \
    --data-binary "@${TSQ_FILE}" \
    --output "${TSR_FILE}")"

if [[ "${HTTP_STATUS}" != "200" ]]; then
    printf 'Error: freetsa.org returned HTTP %s\n' "${HTTP_STATUS}" >&2
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
if ! openssl ts -verify \
        -digest "${MANIFEST_HASH}" \
        -sha256 \
        -in "${TSR_FILE}" \
        -CAfile "${TSA_CA}" \
        -untrusted "${TSA_CERT}" \
        > /dev/null 2>&1; then
    printf 'Error: timestamp token verification failed\n' >&2
    exit 1
fi
echo "  Token verified OK"
TIMESTAMP_LINE="$(openssl ts -reply -in "${TSR_FILE}" -text 2>/dev/null | grep 'Time stamp' || true)"
echo "  ${TIMESTAMP_LINE}"

# ── Step 5: Add manifest.tsr to manifest files[] and record digest ────────────
# manifest.json is modified here (TSR entry added).  The TSR is still verifiable
# because it seals MANIFEST_HASH, not the post-modification file bytes.

echo "[5/5] Adding manifest.tsr to manifest files[] and recording digest..."

TSR_HASHES="$(python3 - "${TSR_FILE}" <<'PY'
import hashlib, sys
data = open(sys.argv[1], 'rb').read()
print(hashlib.sha256(data).hexdigest(), hashlib.sha3_256(data).hexdigest())
PY
)"
TSR_SHA256="${TSR_HASHES%% *}"
TSR_SHA3="${TSR_HASHES##* }"

python3 - "${MANIFEST_FILE}" "${TSR_SHA256}" "${TSR_SHA3}" <<'PY'
import json, sys
manifest_path, tsr_sha256, tsr_sha3 = sys.argv[1:4]
with open(manifest_path) as f:
    manifest = json.load(f)
manifest['files'] = [e for e in manifest.get('files', []) if e.get('role') != 'timestamp']
manifest['files'].append({'name': 'manifest.tsr', 'sha256': tsr_sha256, 'sha3_256': tsr_sha3, 'role': 'timestamp'})
with open(manifest_path, 'w') as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)
    f.write('\n')
print(f"  manifest.tsr added to files[] (role=timestamp)")
print(f"  files[] count: {len(manifest['files'])}")
PY

# Store the pre-TSR manifest hash in bundle-index.json for later timestamp verification.
python3 - "${INDEX_FILE}" "${MANIFEST_HASH}" <<'PY'
import json, sys
index_path, manifest_hash = sys.argv[1:3]
with open(index_path) as f:
    index = json.load(f)
index['timestamp_data_sha256'] = manifest_hash
with open(index_path, 'w') as f:
    json.dump(index, f, indent=2, ensure_ascii=False)
    f.write('\n')
print(f"  timestamp_data_sha256 stored in bundle-index.json")
PY

# ── Summary ───────────────────────────────────────────────────────────────────

printf '\nBundle timestamped: %s\n' "${BUNDLE_DIR}"
printf '  manifest.tsr — RFC 3161 token in manifest files[] (role=timestamp)\n'
printf '  bundle-index.json — timestamp_data_sha256 recorded for verification\n'
printf '\nTo verify the timestamp later:\n'
printf '  DIGEST=%s\n' "${MANIFEST_HASH}"
printf '  openssl ts -verify -digest $DIGEST -sha256 \\\n'
printf '    -in %s/manifest.tsr \\\n' "${BUNDLE_DIR}"
printf '    -CAfile tsa/freetsa-cacert.pem -untrusted tsa/freetsa-tsa.crt\n'
printf '\nNext step:\n'
printf '  bash scripts/sign-bundle.sh %s\n' "$1"
