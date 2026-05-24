#!/usr/bin/env bash
# gen-ca.sh — Generate a test PKI (Ed25519 CA + signer) under pki/
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKI_DIR="${REPO_ROOT}/pki"

CA_KEY="${PKI_DIR}/ca-key.pem"
CA_CERT="${PKI_DIR}/ca-cert.pem"
SIGNER_KEY="${PKI_DIR}/signer-key.pem"
SIGNER_CSR="${PKI_DIR}/signer.csr"
SIGNER_CERT="${PKI_DIR}/signer-cert.pem"

CA_SUBJECT="/CN=RAIN Test Root CA v0/O=Deluge/OU=RAIN Protocol"
SIGNER_SUBJECT="/CN=RAIN Test Signer v0/O=Deluge"

# ---------------------------------------------------------------------------
echo "[1/5] Creating pki/ directory..."
mkdir -p "${PKI_DIR}"

# ---------------------------------------------------------------------------
echo "[2/5] Generating Ed25519 CA private key..."
openssl genpkey -algorithm ed25519 -out "${CA_KEY}"
chmod 600 "${CA_KEY}"

# ---------------------------------------------------------------------------
echo "[3/5] Generating self-signed CA certificate (3650 days)..."
openssl req -new -x509 \
  -key "${CA_KEY}" \
  -out "${CA_CERT}" \
  -days 3650 \
  -subj "${CA_SUBJECT}"

# ---------------------------------------------------------------------------
echo "[4/5] Generating Ed25519 signer key + CSR..."
openssl genpkey -algorithm ed25519 -out "${SIGNER_KEY}"
chmod 600 "${SIGNER_KEY}"

openssl req -new \
  -key "${SIGNER_KEY}" \
  -out "${SIGNER_CSR}" \
  -subj "${SIGNER_SUBJECT}"

echo "[4/5] Signing signer certificate with CA (825 days)..."
openssl x509 -req \
  -in "${SIGNER_CSR}" \
  -CA "${CA_CERT}" \
  -CAkey "${CA_KEY}" \
  -CAcreateserial \
  -out "${SIGNER_CERT}" \
  -days 825

rm -f "${SIGNER_CSR}"

# ---------------------------------------------------------------------------
echo "[5/5] SHA-256 fingerprint of signer certificate (for manifest):"
openssl x509 -in "${SIGNER_CERT}" -noout -fingerprint -sha256

echo ""
echo "Done. Files written to ${PKI_DIR}/"
echo "  CA key  : ${CA_KEY}"
echo "  CA cert : ${CA_CERT}"
echo "  Signer key  : ${SIGNER_KEY}"
echo "  Signer cert : ${SIGNER_CERT}"
echo ""
echo "WARNING: pki/ is in .gitignore — never commit private keys."
