#!/usr/bin/env bash
# test-p3.sh — Suite de tests pour les bundles RAIN P3 (BYOK/HYOK, auto-signé).
#
# Cas testés :
#   1. Création d'un bundle P3 valide → exit 0 + verdict "P3_SELF_SIGNED_IDENTITY_UNVERIFIED"
#      + JSON identity_unverified=true + identity_class=self-signed
#   2. Artwork falsifié → exit 1 (HASH_MISMATCH → INVALID)
#   3. Substitution de certificat → exit 1 (HASH_MISMATCH ou CERT_FINGERPRINT_MISMATCH → INVALID)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLI="${REPO_ROOT}/rain-bundle-cli/rain_cli.py"

PASS=0; FAIL=0

pass() { printf '  [PASS] %s\n' "$1"; (( PASS++ )) || true; }
fail() { printf '  [FAIL] %s\n' "$1"; (( FAIL++ )) || true; }

# ── Prérequis : vérifier que openssl est disponible ───────────────────────────

if ! command -v openssl &>/dev/null; then
    printf '[SKIP] openssl absent — test-p3.sh ignoré\n'
    printf '0 passed, 0 failed, 1 skipped\n'
    exit 0
fi

# ── Setup : répertoire temporaire isolé ───────────────────────────────────────

TMPDIR_P3="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_P3"' EXIT

ARTIST_KEY_DIR="${TMPDIR_P3}/artist-keys"
ARTWORK="${TMPDIR_P3}/test-artwork.png"

# PNG minimal valide (1×1 pixel rouge)
python3 -c "
import struct, zlib, sys
def chunk(name, data):
    crc = zlib.crc32(name + data) & 0xFFFFFFFF
    return struct.pack('>I', len(data)) + name + data + struct.pack('>I', crc)
sig  = b'\x89PNG\r\n\x1a\n'
ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0))
idat = chunk(b'IDAT', zlib.compress(b'\x00\xFF\x00\xFF'))
iend = chunk(b'IEND', b'')
with open(sys.argv[1], 'wb') as f:
    f.write(sig + ihdr + idat + iend)
" "$ARTWORK"

# Génération de la clé artiste (silencieuse)
printf '\n[setup] Génération de la clé artiste P3...\n'
if ! bash "${SCRIPT_DIR}/gen-artist-key.sh" "Test Artist P3" "${ARTIST_KEY_DIR}" \
        >/dev/null 2>&1; then
    printf '[SKIP] gen-artist-key.sh a échoué — test-p3.sh ignoré\n'
    printf '0 passed, 0 failed, 1 skipped\n'
    exit 0
fi
ARTIST_KEY="${ARTIST_KEY_DIR}/artist-key.pem"
ARTIST_CERT="${ARTIST_KEY_DIR}/artist-cert.pem"

if [[ ! -f "$ARTIST_KEY" || ! -f "$ARTIST_CERT" ]]; then
    printf '[SKIP] clés artiste non générées — test-p3.sh ignoré\n'
    printf '0 passed, 0 failed, 1 skipped\n'
    exit 0
fi
printf '  artist-key.pem  : OK\n'
printf '  artist-cert.pem : OK\n'

# ══════════════════════════════════════════════════════════════════════════════
# Cas 1 — Bundle P3 valide : création + vérification + verdicts identitaires
# ══════════════════════════════════════════════════════════════════════════════

printf '\n[cas 1] Bundle P3 valide : création + vérification + verdicts identitaires\n'
BUNDLE_DIR_1="${TMPDIR_P3}/bundle-p3-valid"

CREATE_OUT=""
CREATE_RC=0
CREATE_OUT="$(python3 "$CLI" create \
    --artwork   "$ARTWORK" \
    --output    "$BUNDLE_DIR_1" \
    --purpose   "Test P3 HYOK self-signed" \
    --level     P3 \
    --no-timestamp \
    --artist-key  "$ARTIST_KEY" \
    --artist-cert "$ARTIST_CERT" \
    2>&1)" || CREATE_RC=$?

# 1.1 — Le bundle est créé avec manifest.json et manifest.sig
if [[ -d "$BUNDLE_DIR_1" && -f "${BUNDLE_DIR_1}/manifest.json" && \
      -f "${BUNDLE_DIR_1}/manifest.sig" && -f "${BUNDLE_DIR_1}/artist-cert.pem" ]]; then
    pass "cas 1.1 : bundle P3 créé (manifest.json + manifest.sig + artist-cert.pem)"
else
    fail "cas 1.1 : création du bundle échouée — ${CREATE_OUT}"
fi

# 1.2 — proof_level=P3 dans le manifest
PROOF_LEVEL_IN_MANIFEST=""
PROOF_LEVEL_IN_MANIFEST="$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get('proof_level', ''))
" "${BUNDLE_DIR_1}/manifest.json" 2>/dev/null)" || true

if [[ "$PROOF_LEVEL_IN_MANIFEST" == "P3" ]]; then
    pass "cas 1.2 : proof_level=P3 dans manifest.json"
else
    fail "cas 1.2 : proof_level='${PROOF_LEVEL_IN_MANIFEST}' (attendu P3)"
fi

# 1.3 — signer_identity_class=self-signed dans le manifest
IDENTITY_CLASS_IN_MANIFEST=""
IDENTITY_CLASS_IN_MANIFEST="$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get('signer_identity_class', ''))
" "${BUNDLE_DIR_1}/manifest.json" 2>/dev/null)" || true

if [[ "$IDENTITY_CLASS_IN_MANIFEST" == "self-signed" ]]; then
    pass "cas 1.3 : signer_identity_class=self-signed dans manifest.json"
else
    fail "cas 1.3 : signer_identity_class='${IDENTITY_CLASS_IN_MANIFEST}' (attendu self-signed)"
fi

# 1.4 — verify.sh → exit 0 (VALID)
VERIFY_OUT_1=""
VERIFY_RC_1=0
VERIFY_OUT_1="$(bash "${SCRIPT_DIR}/verify.sh" "$BUNDLE_DIR_1" 2>&1)" || VERIFY_RC_1=$?

if (( VERIFY_RC_1 == 0 )); then
    pass "cas 1.4 : verify.sh → exit 0 (VALID)"
else
    fail "cas 1.4 : verify.sh → exit ${VERIFY_RC_1} (attendu 0) — ${VERIFY_OUT_1}"
fi

# 1.5 — Le verdict contient P3_SELF_SIGNED_IDENTITY_UNVERIFIED
if printf '%s\n' "$VERIFY_OUT_1" | grep -q "P3_SELF_SIGNED_IDENTITY_UNVERIFIED"; then
    pass "cas 1.5 : verdict contient P3_SELF_SIGNED_IDENTITY_UNVERIFIED"
else
    fail "cas 1.5 : verdict ne mentionne pas P3_SELF_SIGNED_IDENTITY_UNVERIFIED — ${VERIFY_OUT_1}"
fi

# 1.6 — JSON : identity_unverified=true + identity_class=self-signed
JSON_OUT_1=""
JSON_RC_1=0
JSON_OUT_1="$(bash "${SCRIPT_DIR}/verify.sh" --json "$BUNDLE_DIR_1" 2>&1)" || JSON_RC_1=$?

JSON_CHECK_RC=0
printf '%s\n' "$JSON_OUT_1" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    print(f'JSON parse error: {e}', file=sys.stderr)
    sys.exit(1)
ok = True
if d.get('identity_unverified') is not True:
    print(f'identity_unverified={d.get(\"identity_unverified\")!r} (attendu True)', file=sys.stderr)
    ok = False
if d.get('identity_class') != 'self-signed':
    print(f'identity_class={d.get(\"identity_class\")!r} (attendu self-signed)', file=sys.stderr)
    ok = False
if d.get('status') != 'VALID':
    print(f'status={d.get(\"status\")!r} (attendu VALID)', file=sys.stderr)
    ok = False
sys.exit(0 if ok else 1)
" 2>/dev/null || JSON_CHECK_RC=$?

if (( JSON_CHECK_RC == 0 )); then
    pass "cas 1.6 : JSON → status=VALID + identity_unverified=true + identity_class=self-signed"
else
    fail "cas 1.6 : JSON incorrect — ${JSON_OUT_1}"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Cas 2 — Artwork falsifié → INVALID (exit 1)
# ══════════════════════════════════════════════════════════════════════════════

printf '\n[cas 2] Artwork falsifié → exit 1 (INVALID)\n'
BUNDLE_DIR_2="${TMPDIR_P3}/bundle-p3-tampered"
cp -r "$BUNDLE_DIR_1" "$BUNDLE_DIR_2"

# Appender des octets à l'artwork dans le bundle
ARTWORK_BASENAME="$(basename "$ARTWORK")"
printf 'FALSIFIE' >> "${BUNDLE_DIR_2}/${ARTWORK_BASENAME}"

VERIFY_RC_2=0
bash "${SCRIPT_DIR}/verify.sh" "$BUNDLE_DIR_2" >/dev/null 2>&1 || VERIFY_RC_2=$?

if (( VERIFY_RC_2 == 1 )); then
    pass "cas 2 : artwork falsifié → exit 1 (INVALID)"
else
    fail "cas 2 : artwork falsifié → exit ${VERIFY_RC_2} (attendu 1)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Cas 3 — Substitution de certificat → INVALID (exit 1)
# ══════════════════════════════════════════════════════════════════════════════

printf '\n[cas 3] Substitution de certificat → exit 1 (INVALID)\n'
BUNDLE_DIR_3="${TMPDIR_P3}/bundle-p3-cert-sub"
cp -r "$BUNDLE_DIR_1" "$BUNDLE_DIR_3"

# Générer une deuxième paire de clés artiste (l'attaquant)
ARTIST_KEY_DIR_2="${TMPDIR_P3}/artist-keys-attacker"
bash "${SCRIPT_DIR}/gen-artist-key.sh" "Attacker" "${ARTIST_KEY_DIR_2}" >/dev/null 2>&1

# Remplacer artist-cert.pem par le cert de l'attaquant (sans toucher au manifest)
CERT_IN_BUNDLE="${BUNDLE_DIR_3}/artist-cert.pem"
if [[ -f "$CERT_IN_BUNDLE" && -f "${ARTIST_KEY_DIR_2}/artist-cert.pem" ]]; then
    cp "${ARTIST_KEY_DIR_2}/artist-cert.pem" "$CERT_IN_BUNDLE"

    VERIFY_RC_3=0
    bash "${SCRIPT_DIR}/verify.sh" "$BUNDLE_DIR_3" >/dev/null 2>&1 || VERIFY_RC_3=$?

    if (( VERIFY_RC_3 == 1 )); then
        pass "cas 3 : substitution de certificat → exit 1 (INVALID)"
    else
        fail "cas 3 : substitution de certificat → exit ${VERIFY_RC_3} (attendu 1)"
    fi
else
    fail "cas 3 : artist-cert.pem absent du bundle — substitution impossible"
fi

# ── Résumé ────────────────────────────────────────────────────────────────────

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
