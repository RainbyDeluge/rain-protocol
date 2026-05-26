#!/usr/bin/env bash
# Test harness pour rain/timestamp_provider.py (FreeTSAProvider).
# Requiert : openssl, python3, accès réseau vers freetsa.org.
# Exit: 0 si tous les cas PASS, 1 si un FAIL.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PROVIDER_MODULE="${REPO_ROOT}/rain-bundle-cli/rain/timestamp_provider.py"
TSA_CA="${REPO_ROOT}/tsa/freetsa-cacert.pem"
TSA_CERT="${REPO_ROOT}/tsa/freetsa-tsa.crt"

PASS=0
FAIL=0

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ── Helpers ────────────────────────────────────────────────────────────────────

pass() { printf 'PASS  %s\n' "$1"; (( PASS++ )) || true; }
fail() { printf 'FAIL  %s  (%s)\n' "$1" "$2"; (( FAIL++ )) || true; }

# ── Pre-flight ─────────────────────────────────────────────────────────────────

if [[ ! -f "${TSA_CA}" ]] || [[ ! -f "${TSA_CERT}" ]]; then
    printf 'Certificats TSA absents — lancez "bash scripts/get-tsa-cert.sh" avant ce test\n'
    printf '0 passed, 0 failed\n'
    exit 0
fi

if ! PYTHONPATH="${REPO_ROOT}/rain-bundle-cli" \
       python3 -c "from rain.timestamp_provider import FreeTSAProvider" 2>/dev/null; then
    printf 'Impossible d'\''importer timestamp_provider — vérifiez le chemin\n'
    printf '0 passed, 0 failed\n'
    exit 1
fi

# ── Digest de test (SHA-256 d'une chaîne constante) ────────────────────────────

DIGEST="$(python3 -c "import hashlib; print(hashlib.sha256(b'rain-ts-test-v1').hexdigest())")"
printf 'digest de test : %s\n\n' "$DIGEST"

# ── Cas 1 : FreeTSAProvider retourne un jeton non vide ──────────────────────────

LABEL="FreeTSAProvider.timestamp() → jeton RFC 3161 non vide"
TSR_FILE="${TMPDIR_TEST}/test.tsr"
if PYTHONPATH="${REPO_ROOT}/rain-bundle-cli" python3 - "$DIGEST" "$TSR_FILE" <<'PY' 2>/dev/null; then
import sys, base64
from rain.timestamp_provider import FreeTSAProvider
digest_hex, out_path = sys.argv[1], sys.argv[2]
tsr = FreeTSAProvider().timestamp(digest_hex)
if not tsr:
    print("jeton vide", file=sys.stderr)
    sys.exit(1)
open(out_path, "wb").write(tsr)
print(f"  {len(tsr)} octets reçus")
PY
    if [[ -s "$TSR_FILE" ]]; then
        pass "$LABEL"
    else
        fail "$LABEL" "fichier TSR vide après appel réussi"
    fi
else
    fail "$LABEL" "FreeTSAProvider.timestamp() a levé une exception"
fi

# ── Cas 2 : messageImprint du jeton correspond au digest fourni ────────────────
# Vérifie via openssl ts -verify que le TSR porte bien le digest demandé.

LABEL="messageImprint du jeton == digest fourni (openssl ts -verify)"
if [[ -s "$TSR_FILE" ]]; then
    if openssl ts -verify \
            -digest "$DIGEST" \
            -sha256 \
            -in "$TSR_FILE" \
            -CAfile "$TSA_CA" \
            -untrusted "$TSA_CERT" \
            > /dev/null 2>&1; then
        pass "$LABEL"
    else
        fail "$LABEL" "openssl ts -verify a échoué — messageImprint ne correspond pas"
    fi
else
    fail "$LABEL" "TSR absent (cas 1 échoué)"
fi

# ── Cas 3 : genTime lisible depuis le jeton ────────────────────────────────────
# Vérifie qu'un horodatage est bien inclus dans le token (extraction textuelle).

LABEL="jeton contient un genTime lisible"
if [[ -s "$TSR_FILE" ]]; then
    GEN_TIME="$(openssl ts -reply -in "$TSR_FILE" -text 2>/dev/null | grep 'Time stamp:' | sed 's/.*Time stamp: //')"
    if [[ -n "$GEN_TIME" ]]; then
        printf '  genTime : %s\n' "$GEN_TIME"
        pass "$LABEL"
    else
        fail "$LABEL" "aucun 'Time stamp:' dans la sortie openssl ts -reply -text"
    fi
else
    fail "$LABEL" "TSR absent (cas 1 échoué)"
fi

# ── Cas 4 : TimestampError levée proprement sur URL invalide (cas réseau KO) ──

LABEL="TimestampError levée sur URL invalide (réseau KO simulé)"
if PYTHONPATH="${REPO_ROOT}/rain-bundle-cli" python3 - "$DIGEST" <<'PY' 2>/dev/null; then
import sys
from rain.timestamp_provider import FreeTSAProvider, TimestampError
digest_hex = sys.argv[1]
try:
    FreeTSAProvider(timeout=5, url="http://127.0.0.1:19999/tsr").timestamp(digest_hex)
    print("ERREUR : aucune exception levée", file=sys.stderr)
    sys.exit(1)
except TimestampError as exc:
    print(f"  TimestampError correctement levée : {exc}")
    sys.exit(0)
except Exception as exc:
    print(f"  Exception inattendue (pas TimestampError) : {type(exc).__name__}: {exc}", file=sys.stderr)
    sys.exit(1)
PY
    pass "$LABEL"
else
    fail "$LABEL" "TimestampError non levée ou exception inattendue"
fi

# ── Cas 5 : TimestampError levée sur digest malformé ──────────────────────────

LABEL="TimestampError levée sur digest malformé (pas 64 chars hex)"
if PYTHONPATH="${REPO_ROOT}/rain-bundle-cli" python3 - <<'PY' 2>/dev/null; then
import sys
from rain.timestamp_provider import FreeTSAProvider, TimestampError
try:
    FreeTSAProvider().timestamp("not-a-valid-hex-digest")
    print("ERREUR : aucune exception levée", file=sys.stderr)
    sys.exit(1)
except TimestampError as exc:
    print(f"  TimestampError correctement levée : {exc}")
    sys.exit(0)
except Exception as exc:
    print(f"  Exception inattendue : {type(exc).__name__}: {exc}", file=sys.stderr)
    sys.exit(1)
PY
    pass "$LABEL"
else
    fail "$LABEL" "TimestampError non levée sur digest malformé"
fi

# ── Résumé ─────────────────────────────────────────────────────────────────────

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
