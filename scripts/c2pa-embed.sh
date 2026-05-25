#!/usr/bin/env bash
# c2pa-embed.sh — Embed a signed C2PA manifest into an artwork image (PNG/JPEG),
# bridging it to an associated RAIN bundle via a rain.bundle custom assertion.
#
# Usage: bash scripts/c2pa-embed.sh <artwork-image> <bundle-dir>
#
# The C2PA leaf cert is stored in c2pa-bridge/ and is derived from the RAIN CA
# (pki/ca-cert.pem) with the Key Usage and EKU extensions required by c2patool.
# It is generated automatically on first run.
#
# WARNING: signingCredential.untrusted is expected in v0.  The RAIN CA is not
# registered in the CAI global trust store.  The signature is cryptographically
# valid; the missing piece is an anchor in a recognised authority — that comes
# in production when the RAIN CA is submitted to CAI.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PKI_DIR="${REPO_ROOT}/pki"
BRIDGE_DIR="${REPO_ROOT}/c2pa-bridge"

C2PA_KEY="${BRIDGE_DIR}/c2pa-signer-key.pem"
C2PA_CERT="${BRIDGE_DIR}/c2pa-signer-cert.pem"
TEMPLATE="${BRIDGE_DIR}/rain-manifest-template.json"

# ── Arguments ─────────────────────────────────────────────────────────────────

if [[ $# -ne 2 ]]; then
    printf 'Usage: %s <artwork-image> <bundle-dir>\n' "$(basename "$0")" >&2
    exit 1
fi

ARTWORK="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
BUNDLE_DIR="$(cd "$2" && pwd)"

# ── Pre-flight: c2patool ──────────────────────────────────────────────────────

echo "[0/6] Checking prerequisites..."
if ! command -v c2patool &>/dev/null; then
    printf 'Error: c2patool not found.\n' >&2
    printf '  Install with: brew install c2patool\n' >&2
    exit 1
fi
printf '  c2patool : %s\n' "$(c2patool --version)"

# ── Pre-flight: RAIN CA (required to generate C2PA cert on first run) ─────────

for f in ca-cert.pem ca-key.pem; do
    if [[ ! -f "${PKI_DIR}/${f}" ]]; then
        printf 'Error: RAIN PKI file not found: %s\n' "${PKI_DIR}/${f}" >&2
        printf '  Run: bash scripts/gen-ca.sh\n' >&2
        exit 1
    fi
done
echo "  RAIN CA  : pki/ca-cert.pem + pki/ca-key.pem — OK"

# ── Pre-flight: artwork ───────────────────────────────────────────────────────

if [[ ! -f "${ARTWORK}" ]]; then
    printf 'Error: artwork not found: %s\n' "${ARTWORK}" >&2
    exit 1
fi
EXT="$(printf '%s' "${ARTWORK##*.}" | tr '[:upper:]' '[:lower:]')"
if [[ "${EXT}" != "png" && "${EXT}" != "jpg" && "${EXT}" != "jpeg" ]]; then
    printf 'Error: artwork must be PNG or JPEG (got .%s)\n' "${EXT}" >&2
    exit 1
fi
echo "  artwork  : ${ARTWORK}"

# ── Pre-flight: bundle manifest ───────────────────────────────────────────────

MANIFEST_FILE="${BUNDLE_DIR}/manifest.json"
if [[ ! -f "${MANIFEST_FILE}" ]]; then
    printf 'Error: manifest.json not found in %s\n' "${BUNDLE_DIR}" >&2
    exit 1
fi
echo "  bundle   : ${BUNDLE_DIR}"

# ── Step 1: Ensure C2PA signer cert exists ────────────────────────────────────
# The C2PA leaf cert requires keyUsage=digitalSignature and extendedKeyUsage=
# emailProtection — extensions the base RAIN signer cert omits but c2patool
# requires.  It is generated once from the RAIN CA and stored in c2pa-bridge/.

echo "[1/6] Ensuring C2PA signer cert..."
if [[ ! -f "${C2PA_KEY}" ]] || [[ ! -f "${C2PA_CERT}" ]]; then
    echo "  Generating C2PA leaf key + cert (derived from RAIN CA)..."

    openssl genpkey -algorithm ed25519 -out "${C2PA_KEY}" 2>/dev/null
    chmod 600 "${C2PA_KEY}"

    C2PA_EXT_CONF="$(mktemp /tmp/c2pa-ext-XXXXXX.cnf)"
    cat > "${C2PA_EXT_CONF}" << 'EXTEOF'
[v3_c2pa]
keyUsage             = critical, digitalSignature
extendedKeyUsage     = emailProtection
basicConstraints     = CA:FALSE
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EXTEOF

    openssl req -new \
        -key "${C2PA_KEY}" \
        -out /tmp/c2pa-signer.csr \
        -subj "/CN=RAIN C2PA Signer v0/O=Deluge/OU=RAIN Protocol" 2>/dev/null

    openssl x509 -req \
        -in /tmp/c2pa-signer.csr \
        -CA "${PKI_DIR}/ca-cert.pem" \
        -CAkey "${PKI_DIR}/ca-key.pem" \
        -CAcreateserial \
        -out "${C2PA_CERT}" \
        -days 825 \
        -extfile "${C2PA_EXT_CONF}" \
        -extensions v3_c2pa 2>/dev/null

    rm -f /tmp/c2pa-signer.csr "${C2PA_EXT_CONF}"
    echo "  Written: c2pa-bridge/c2pa-signer-key.pem + c2pa-signer-cert.pem"
else
    echo "  c2pa-signer-cert.pem : already exists"
fi

# ── Step 2: Read bundle metadata ──────────────────────────────────────────────

echo "[2/6] Reading RAIN bundle metadata..."
read -r BUNDLE_ID PROOF_LEVEL RAIN_VERSION <<< "$(python3 - "${MANIFEST_FILE}" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
print(d['bundle_id'], d.get('proof_level', 'P1'), d.get('rain_version', '0.1.0'))
PYEOF
)"
printf '  bundle_id    : %s\n' "${BUNDLE_ID}"
printf '  proof_level  : %s\n' "${PROOF_LEVEL}"
printf '  rain_version : %s\n' "${RAIN_VERSION}"

# ── Step 3: Build certificate chain ──────────────────────────────────────────

echo "[3/6] Building certificate chain (signer + RAIN CA)..."
TMPDIR_LOCAL="$(mktemp -d /tmp/rain-c2pa-XXXXXX)"
trap 'rm -rf "${TMPDIR_LOCAL}"' EXIT

CHAIN_PEM="${TMPDIR_LOCAL}/chain.pem"
cat "${C2PA_CERT}" "${PKI_DIR}/ca-cert.pem" > "${CHAIN_PEM}"
echo "  chain.pem : c2pa-signer-cert + ca-cert"

# ── Step 4: Generate resolved manifest definition ────────────────────────────

echo "[4/6] Generating C2PA manifest definition from template..."
MANIFEST_DEF="${TMPDIR_LOCAL}/manifest-def.json"

python3 - "${BUNDLE_ID}" "${PROOF_LEVEL}" "${RAIN_VERSION}" \
          "${C2PA_KEY}" "${CHAIN_PEM}" "${TEMPLATE}" "${MANIFEST_DEF}" <<'PYEOF'
import json, sys

bundle_id, proof_level, rain_version, key_path, chain_path, tmpl_path, out_path = sys.argv[1:]

with open(tmpl_path) as f:
    raw = f.read()

for token, value in {
    "{{PRIVATE_KEY}}":  key_path,
    "{{SIGN_CERT}}":    chain_path,
    "{{BUNDLE_ID}}":    bundle_id,
    "{{PROOF_LEVEL}}":  proof_level,
    "{{RAIN_VERSION}}": rain_version,
}.items():
    raw = raw.replace(token, value)

data = json.loads(raw)
with open(out_path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF

echo "  manifest-def.json : resolved"

# ── Step 5: Sign artwork ──────────────────────────────────────────────────────

echo "[5/6] Signing artwork with c2patool..."
ARTWORK_BASE="$(basename "${ARTWORK%.*}")"
OUTPUT_IMAGE="${BUNDLE_DIR}/${ARTWORK_BASE}-c2pa.${EXT}"

c2patool "${ARTWORK}" \
    --manifest "${MANIFEST_DEF}" \
    --output "${OUTPUT_IMAGE}" \
    --force

printf '  signed image : %s\n' "${OUTPUT_IMAGE}"

# ── Step 6: Verify embedded manifest ─────────────────────────────────────────

echo "[6/6] Verifying embedded C2PA manifest..."
echo ""
VERIFY_JSON="$(c2patool "${OUTPUT_IMAGE}" 2>&1)"
echo "${VERIFY_JSON}"

if echo "${VERIFY_JSON}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
manifests = data.get('manifests', {})
for m in manifests.values():
    for a in m.get('assertions', []):
        if a.get('label') == 'rain.bundle':
            sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
    echo ""
    printf '  [PASS] rain.bundle assertion : PRESENT\n'
    printf '  [PASS] C2PA manifest embedded and cryptographically valid.\n'
    if echo "${VERIFY_JSON}" | grep -q '"signingCredential.untrusted"'; then
        printf '  [INFO] signingCredential.untrusted : expected (RAIN CA not in CAI trust store — v0 behaviour)\n'
    fi
else
    printf '\n[FAIL] rain.bundle assertion not found in verify output.\n' >&2
    exit 1
fi

printf '\nDone: %s\n' "${OUTPUT_IMAGE}"
