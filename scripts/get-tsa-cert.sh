#!/usr/bin/env bash
# get-tsa-cert.sh — Download freetsa.org TSA and CA certificates for RFC 3161 timestamp verification
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TSA_DIR="${REPO_ROOT}/tsa"

TSA_CERT_URL="https://freetsa.org/files/tsa.crt"
TSA_CA_URL="https://freetsa.org/files/cacert.pem"

TSA_CERT="${TSA_DIR}/freetsa-tsa.crt"
TSA_CA="${TSA_DIR}/freetsa-cacert.pem"

# ── Step 1: Create tsa/ directory ────────────────────────────────────────────

echo "[1/4] Creating tsa/ directory..."
mkdir -p "${TSA_DIR}"

# ── Step 2: Download certificates ────────────────────────────────────────────

echo "[2/4] Downloading TSA certificate..."
if ! curl --fail --silent --show-error --location \
     --output "${TSA_CERT}" "${TSA_CERT_URL}"; then
    printf 'Error: failed to download TSA certificate from %s\n' "${TSA_CERT_URL}" >&2
    printf 'Check network connectivity and try again.\n' >&2
    exit 1
fi
echo "  written: tsa/freetsa-tsa.crt"

echo "[2/4] Downloading TSA root CA certificate..."
if ! curl --fail --silent --show-error --location \
     --output "${TSA_CA}" "${TSA_CA_URL}"; then
    printf 'Error: failed to download CA certificate from %s\n' "${TSA_CA_URL}" >&2
    printf 'Check network connectivity and try again.\n' >&2
    exit 1
fi
echo "  written: tsa/freetsa-cacert.pem"

# ── Step 3: Verify files are non-empty ───────────────────────────────────────

echo "[3/4] Verifying downloaded files..."
for f in "${TSA_CERT}" "${TSA_CA}"; do
    if [[ ! -s "$f" ]]; then
        printf 'Error: file is empty: %s\n' "$f" >&2
        exit 1
    fi
    echo "  OK: $(basename "$f") ($(wc -c < "$f" | tr -d ' ') bytes)"
done

# ── Step 4: Display TSA certificate details ───────────────────────────────────

echo "[4/4] TSA certificate details:"
openssl x509 -in "${TSA_CERT}" -noout \
    -subject -dates

echo ""
echo "Done. Certificates installed in ${TSA_DIR}/"
echo "  freetsa-tsa.crt    — TSA signing certificate"
echo "  freetsa-cacert.pem — freetsa.org root CA"
