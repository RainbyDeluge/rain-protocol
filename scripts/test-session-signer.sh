#!/usr/bin/env bash
# Test harness pour rain/session_signer.py — logique de chaînage session-signed.
# Tests entièrement isolés : itérations factices, aucun appel à mals_capture.py
# ni à verify.sh. Deux appels réseau réels vers freetsa.org (cas b).
# Exit: 0 si tous les cas PASS, 1 si un FAIL.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PYPATH="${REPO_ROOT}/rain-bundle-cli"
CERT="${REPO_ROOT}/pki/signer-cert.pem"
TSA_CA="${REPO_ROOT}/tsa/freetsa-cacert.pem"
TSA_CERT="${REPO_ROOT}/tsa/freetsa-tsa.crt"

PASS=0
FAIL=0
SKIP=0

# ── Helpers ────────────────────────────────────────────────────────────────────

pass() { printf 'PASS  %s\n' "$1"; (( PASS++ )) || true; }
fail() { printf 'FAIL  %s  (%s)\n' "$1" "$2"; (( FAIL++ )) || true; }
skip() { printf 'SKIP  %s  (%s)\n' "$1" "$2"; (( SKIP++ )) || true; }

py() { PYTHONPATH="$PYPATH" python3 "$@"; }

# ── Pre-flight ─────────────────────────────────────────────────────────────────

if [[ ! -f "${CERT}" ]]; then
    printf 'PKI absente — lancez "bash scripts/gen-ca.sh"\n'
    printf '0 passed, 0 failed\n'
    exit 0
fi

if ! py -c "from rain.session_signer import build_signed_iterations" 2>/dev/null; then
    printf 'Impossible d'\''importer session_signer\n'
    printf '0 passed, 0 failed\n'
    exit 1
fi

# ── Itérations factices partagées ─────────────────────────────────────────────

# Trois itérations simulant une session réelle (hashes SHA-256 de chaînes fictives)
read -r -d '' FAKE_ITERS <<'JSON' || true
[
  {"seq": 1, "action": "generate",
   "input_hash":  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
   "output_hash": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
  {"seq": 2, "action": "generate",
   "input_hash":  "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
   "output_hash": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"},
  {"seq": 3, "action": "generate",
   "input_hash":  "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
   "output_hash": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"}
]
JSON

# ── Cas a : chaîne 3 itérations SANS TSA → tsa_status="pending", verify OK ────

printf '\n── Cas a : chaîne sans TSA (tsa_status=pending) ──────────────────────────\n'
LABEL="a — chaîne 3 itérations sans TSA : toutes pending, verify_signed_chain valide"
if py - "$CERT" <<PY 2>/dev/null; then
import json, sys, base64
from rain.session_signer import build_signed_iterations, verify_signed_chain, GENESIS_PREV_SIG_HASH

iters_data = $FAKE_ITERS
cert_pem = open(sys.argv[1], "rb").read()

# Construit sans provider TSA
chain = build_signed_iterations(iters_data)

# Vérifie que tous sont "pending"
bad = [i["seq"] for i in chain if i.get("tsa_status") != "pending"]
if bad:
    print(f"  ERREUR : tsa_status != 'pending' pour seq={bad}", file=sys.stderr)
    sys.exit(1)

# Vérifie la genèse
if chain[0]["prev_sig_hash"] != GENESIS_PREV_SIG_HASH:
    print("  ERREUR : prev_sig_hash de seq=1 != genèse", file=sys.stderr)
    sys.exit(1)

# Vérifie les chaînages intermédiaires
import hashlib
for idx in range(1, len(chain)):
    prev_sig_bytes = base64.b64decode(chain[idx-1]["sig"])
    expected = hashlib.sha256(prev_sig_bytes).hexdigest()
    if chain[idx]["prev_sig_hash"] != expected:
        print(f"  ERREUR : chaînage rompu entre seq={idx} et seq={idx+1}", file=sys.stderr)
        sys.exit(1)

# Vérifie les signatures
result = verify_signed_chain(chain, cert_pem)
if not result.valid:
    print(f"  ERREUR verify_signed_chain : {result.error}", file=sys.stderr)
    sys.exit(1)

print(f"  {len(chain)} itérations, toutes pending, chaîne valide")
sys.exit(0)
PY
    pass "$LABEL"
else
    fail "$LABEL" "exception Python ou vérification échouée"
fi

# ── Cas b : chaîne 2 itérations AVEC FreeTSAProvider réel (2 appels réseau) ──
# Pré-sonde freetsa.org (timeout 8s) — si injoignable, cas ignoré (SKIP).
# Coût : 2 appels gratuits vers freetsa.org si le réseau répond.

printf '\n── Cas b : chaîne avec FreeTSAProvider réel (2 appels freetsa.org) ──────\n'
LABEL="b — tsa_status=anchored, ts_token présent et messageImprint cohérent"

_FREETSA_UP=false
if py -c "
import hashlib
from rain.timestamp_provider import FreeTSAProvider, TimestampError
try:
    FreeTSAProvider(timeout=8).timestamp(hashlib.sha256(b'probe').hexdigest())
    exit(0)
except TimestampError:
    exit(1)
" 2>/dev/null; then
    _FREETSA_UP=true
fi

if [[ "${_FREETSA_UP}" == false ]]; then
    skip "$LABEL" "freetsa.org injoignable — test ignoré (réseau requis)"
else
    TMPDIR_B="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR_B"' EXIT

    if py - "$CERT" "$TSA_CA" "$TSA_CERT" "$TMPDIR_B" <<'PY' 2>/dev/null; then
import sys, base64, hashlib, subprocess, os
from rain.session_signer import build_signed_iterations, verify_signed_chain
from rain.timestamp_provider import FreeTSAProvider

cert_pem = open(sys.argv[1], "rb").read()
tsa_ca, tsa_cert, tmpdir = sys.argv[2], sys.argv[3], sys.argv[4]

iters_data = [
    {"seq": 1, "action": "generate", "input_hash": "a"*64, "output_hash": "b"*64},
    {"seq": 2, "action": "generate", "input_hash": "c"*64, "output_hash": "d"*64},
]

chain = build_signed_iterations(iters_data, timestamp_provider=FreeTSAProvider())

bad = [i["seq"] for i in chain if i.get("tsa_status") != "anchored"]
if bad:
    print(f"  ERREUR : tsa_status != 'anchored' pour seq={bad}", file=sys.stderr); sys.exit(1)

for it in chain:
    tsr_bytes = base64.b64decode(it["ts_token"])
    sig_bytes  = base64.b64decode(it["sig"])
    digest     = hashlib.sha256(sig_bytes).hexdigest()
    tsr_path   = os.path.join(tmpdir, f"seq{it['seq']}.tsr")
    open(tsr_path, "wb").write(tsr_bytes)
    r = subprocess.run(
        ["openssl", "ts", "-verify", "-digest", digest, "-sha256",
         "-in", tsr_path, "-CAfile", tsa_ca, "-untrusted", tsa_cert],
        capture_output=True,
    )
    if r.returncode != 0:
        print(f"  ERREUR seq={it['seq']} : openssl ts -verify échoué", file=sys.stderr)
        sys.exit(1)
    print(f"  seq={it['seq']} : ts_token OK — messageImprint cohérent")

result = verify_signed_chain(chain, cert_pem)
if not result.valid:
    print(f"  ERREUR verify_signed_chain : {result.error}", file=sys.stderr); sys.exit(1)
print("  verify_signed_chain : valide")
sys.exit(0)
PY
        pass "$LABEL"
    else
        fail "$LABEL" "ts_token invalide ou chaîne incorrecte"
    fi
fi

# ── Cas c : ALTÉRATION — rupture de signature détectée ────────────────────────

printf '\n── Cas c : altération d'\''une itération → signature invalide détectée ──────\n'
LABEL="c — output_hash altéré → verify_signed_chain détecte la rupture (seq=2)"
if py - "$CERT" <<PY 2>/dev/null; then
import sys
from rain.session_signer import build_signed_iterations, verify_signed_chain

iters_data = $FAKE_ITERS
cert_pem = open(sys.argv[1], "rb").read()

chain = build_signed_iterations(iters_data)

# Altère output_hash de seq=2 après signature
chain[1]["output_hash"] = "0" * 64

result = verify_signed_chain(chain, cert_pem)
if result.valid:
    print("  ERREUR : la chaîne aurait dû être invalide (altération non détectée)", file=sys.stderr)
    sys.exit(1)

print(f"  Rupture détectée : seq={result.failed_seq}")
print(f"  Raison : {result.error}")
# L'altération est sur seq=2, donc la signature de seq=2 est invalide
if result.failed_seq != 2:
    print(f"  ERREUR : failed_seq attendu 2, obtenu {result.failed_seq}", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
    pass "$LABEL"
else
    fail "$LABEL" "altération non détectée ou exception"
fi

# ── Cas d : RÉORDONNANCEMENT — chaînage brisé ─────────────────────────────────

printf '\n── Cas d : réordonnancement → chaînage brisé détecté ───────────────────\n'
LABEL="d — échange seq=1 et seq=2 → rupture de chaînage détectée"
if py - "$CERT" <<PY 2>/dev/null; then
import sys
from rain.session_signer import build_signed_iterations, verify_signed_chain

iters_data = $FAKE_ITERS
cert_pem = open(sys.argv[1], "rb").read()

chain = build_signed_iterations(iters_data)

# Réordonne : met seq=2 en première position, seq=1 en deuxième
reordered = [chain[1], chain[0], chain[2]]

result = verify_signed_chain(reordered, cert_pem)
if result.valid:
    print("  ERREUR : le réordonnancement n'a pas été détecté", file=sys.stderr)
    sys.exit(1)

print(f"  Rupture détectée : seq={result.failed_seq}")
print(f"  Raison : {result.error}")
sys.exit(0)
PY
    pass "$LABEL"
else
    fail "$LABEL" "réordonnancement non détecté ou exception"
fi

# ── Cas e : ÉCHEC TSA — chaîne construite quand même (non bloquant) ───────────

printf '\n── Cas e : échec TSA → principe non bloquant, tsa_status=failed ─────────\n'
LABEL="e — provider URL invalide → tsa_status=failed sur toutes les itérations, chaîne valide"
if py - "$CERT" <<PY 2>/dev/null; then
import sys
from rain.session_signer import build_signed_iterations, verify_signed_chain
from rain.timestamp_provider import FreeTSAProvider

iters_data = $FAKE_ITERS
cert_pem = open(sys.argv[1], "rb").read()

# Provider avec URL invalide → TimestampError garantie
bad_provider = FreeTSAProvider(timeout=3, url="http://127.0.0.1:19999/tsr")

# PRINCIPE NON BLOQUANT : ne doit PAS lever d'exception
chain = build_signed_iterations(iters_data, timestamp_provider=bad_provider)

# Toutes les itérations doivent être "failed"
bad = [i["seq"] for i in chain if i.get("tsa_status") != "failed"]
if bad:
    print(f"  ERREUR : tsa_status != 'failed' pour seq={bad}", file=sys.stderr)
    sys.exit(1)

# Aucune ne doit avoir de ts_token
with_token = [i["seq"] for i in chain if "ts_token" in i]
if with_token:
    print(f"  ERREUR : ts_token présent malgré échec TSA pour seq={with_token}", file=sys.stderr)
    sys.exit(1)

# La chaîne doit rester cryptographiquement valide
result = verify_signed_chain(chain, cert_pem)
if not result.valid:
    print(f"  ERREUR verify_signed_chain : {result.error}", file=sys.stderr)
    sys.exit(1)

print(f"  {len(chain)} itérations construites malgré l'échec TSA")
print(f"  tsa_status='failed' sur toutes — aucun ts_token")
print(f"  verify_signed_chain : valide (chaîne cryptographiquement intacte)")
sys.exit(0)
PY
    pass "$LABEL"
else
    fail "$LABEL" "exception levée ou chaîne invalide malgré échec TSA"
fi

# ── Résumé ─────────────────────────────────────────────────────────────────────

if (( SKIP > 0 )); then
    printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
else
    printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
fi
(( FAIL == 0 ))
