#!/usr/bin/env bash
# Test harness for MALS capture and log validation.
# All tests run offline: StubProvider for capture, static fixtures for schema tests.
# No real API key is ever used or required.
# Exit: 0 if all cases PASS, 1 if any FAIL.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MALS_CLI="${REPO_ROOT}/rain-bundle-cli/mals_cli.py"
SCHEMA="${REPO_ROOT}/schemas/mals-log.schema.json"

PASS=0
FAIL=0

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ── Helpers ────────────────────────────────────────────────────────────────────

pass() { printf 'PASS  %s\n' "$1"; (( PASS++ )) || true; }
fail() { printf 'FAIL  %s  (%s)\n' "$1" "$2"; (( FAIL++ )) || true; }

# Validate $2 (JSON file) against $1 (schema file).
# Exit 0 if valid, 1 if invalid, 2 if jsonschema not installed.
py_validate() {
    local schema_file="$1" doc_file="$2"
    python3 - "$schema_file" "$doc_file" <<'PY'
import json, sys
try:
    from jsonschema import Draft202012Validator
except ImportError:
    print("jsonschema not installed — run: pip install jsonschema", file=sys.stderr)
    sys.exit(2)
schema = json.loads(open(sys.argv[1]).read())
doc    = json.loads(open(sys.argv[2]).read())
errors = list(Draft202012Validator(schema).iter_errors(doc))
if errors:
    for e in errors[:3]:
        print(f"  schema-err: {e.message}", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
}

# ── Shared test fixture: multi-provider stub capture ──────────────────────────
# Prompt file targets anthropic, openai, gemini — all are stubbed via
# --stub-providers so no real API call is made.
# Fake API keys are exported inline so the pre-call key-check (which guards
# against missing credentials) does not block; StubProvider never reads them.

STUB_PROMPTS="${TMPDIR_TEST}/prompts-stub.txt"
cat > "$STUB_PROMPTS" <<'EOF'
anthropic: Premier prompt de test stub.
openai: Deuxième prompt de test stub.
gemini: Troisième prompt de test stub.
EOF

STUB_LOG="${TMPDIR_TEST}/stub-multi.json"

# ── Case 1: Stub capture produces a schema-valid multi-provider mals-log ──────

LABEL="stub-multi-capture → mals-log valide contre le schéma"
if ANTHROPIC_API_KEY=stub-key OPENAI_API_KEY=stub-key GEMINI_API_KEY=stub-key \
   python3 "$MALS_CLI" capture \
       --prompts "$STUB_PROMPTS" \
       --output  "$STUB_LOG" \
       --stub-providers anthropic,openai,gemini \
       --yes \
   > /dev/null 2>&1 \
   && [[ -f "$STUB_LOG" ]]; then
    rc=0; py_validate "$SCHEMA" "$STUB_LOG" > /dev/null 2>&1 || rc=$?
    if (( rc == 0 )); then
        pass "$LABEL"
    elif (( rc == 2 )); then
        fail "$LABEL" "jsonschema non installé"
    else
        fail "$LABEL" "schéma invalide — voir erreurs ci-dessus"
    fi
else
    fail "$LABEL" "mals_cli.py capture a échoué"
fi

# ── Case 2: Stubbed log contains no real provider name (anti-regression) ──────
# Guard against the previously-fixed bug where StubProvider could disguise
# itself as a real provider. Every iteration must show provider="stub".

LABEL="stub-log → aucun vrai fournisseur dans les itérations (provider=stub partout)"
if [[ -f "$STUB_LOG" ]]; then
    if python3 - "$STUB_LOG" <<'PY'; then
import json, sys
log = json.load(open(sys.argv[1]))
REAL = {"anthropic", "openai", "gemini"}
errors = []
for it in log.get("iterations", []):
    prov = it.get("provider", "")
    if prov in REAL:
        errors.append(f"iteration seq={it['seq']} provider={prov!r} — un vrai nom de fournisseur ne doit jamais apparaître dans un log stubé")
    if "provider" in it and it["provider"] != "stub":
        errors.append(f"iteration seq={it['seq']} provider={it['provider']!r}, attendu 'stub'")
    if "model" in it and it["model"] != "stub-v1":
        errors.append(f"iteration seq={it['seq']} model={it['model']!r}, attendu 'stub-v1'")
if errors:
    for e in errors:
        print(f"  {e}", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
        pass "$LABEL"
    else
        fail "$LABEL" "vrai fournisseur trouvé dans un log entièrement stubé"
    fi
else
    fail "$LABEL" "log absent (cas 1 échoué)"
fi

# ── Case 3: session_hash matches independent SHA-256 recalculation ────────────
# Verify the hash-chain formula: SHA-256(concat(input_hash_i + output_hash_i)).

LABEL="session_hash correspond au SHA-256 recalculé indépendamment"
if [[ -f "$STUB_LOG" ]]; then
    if python3 - "$STUB_LOG" <<'PY'; then
import hashlib, json, sys
log = json.load(open(sys.argv[1]))
its = log.get("iterations", [])
concat   = "".join(it["input_hash"] + it["output_hash"] for it in its)
expected = hashlib.sha256(concat.encode("utf-8")).hexdigest()
actual   = log.get("session_hash", "")
if actual != expected:
    print(f"  attendu : {expected}", file=sys.stderr)
    print(f"  réel    : {actual}",   file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
        pass "$LABEL"
    else
        fail "$LABEL" "session_hash ne correspond pas au recalcul"
    fi
else
    fail "$LABEL" "log absent (cas 1 échoué)"
fi

# ── Case 4: Log contains only hashes — no plaintext fields ───────────────────
# All hash fields must match ^[0-9a-f]{64}$.
# No forbidden plaintext fields (prompt, text, content, response, completion).

LABEL="confidentialité — hashes 64-char hex uniquement, aucun champ texte"
if [[ -f "$STUB_LOG" ]]; then
    if python3 - "$STUB_LOG" <<'PY'; then
import json, re, sys
log = json.load(open(sys.argv[1]))
HASH_RX  = re.compile(r'^[0-9a-f]{64}$')
FORBIDDEN = {"prompt", "text", "content", "response", "completion", "output"}
errors = []

if not HASH_RX.match(log.get("session_hash", "")):
    errors.append(f"session_hash invalide : {log.get('session_hash', '')!r}")

for it in log.get("iterations", []):
    for hf in ("input_hash", "output_hash"):
        if hf in it and not HASH_RX.match(it[hf]):
            errors.append(f"iterations[{it['seq']}].{hf} n'est pas un hash 64-char hex")
    for k in FORBIDDEN:
        if k in it:
            errors.append(f"iterations[{it['seq']}] contient le champ interdit '{k}'")

for k in FORBIDDEN:
    if k in log:
        errors.append(f"champ interdit au niveau session : '{k}'")

if errors:
    for e in errors:
        print(f"  {e}", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
        pass "$LABEL"
    else
        fail "$LABEL" "contenu en clair ou hash invalide détecté"
    fi
else
    fail "$LABEL" "log absent (cas 1 échoué)"
fi

# ── Case 5: Pre-built mono-provider log validates against schema (compat) ─────
# Simulates a legacy single-provider log: provider/model at session level,
# no per-iteration provider/model fields.

LABEL="log mono-fournisseur (legacy) → schéma valide"
MONO_LOG="${TMPDIR_TEST}/mono-log.json"
python3 - "$MONO_LOG" <<'PY'
import hashlib, json, sys, uuid
from datetime import datetime, timezone
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
def h(s): return hashlib.sha256(s.encode()).hexdigest()
it = {"seq": 1, "action": "generate",
      "input_hash": h("prompt-test-1"), "output_hash": h("reponse-test-1"), "ts": now}
log = {
    "session_id":        str(uuid.uuid4()),
    "provider":          "anthropic",
    "model":             "claude-haiku-4-5-20251001",
    "source_class":      "native",
    "attestation_class": "post-session",
    "started_at":        now,
    "ended_at":          now,
    "iterations":        [it],
    "session_hash":      hashlib.sha256((it["input_hash"] + it["output_hash"]).encode()).hexdigest(),
}
json.dump(log, open(sys.argv[1], "w"), indent=2)
PY
rc=0; py_validate "$SCHEMA" "$MONO_LOG" > /dev/null 2>&1 || rc=$?
if (( rc == 0 )); then
    pass "$LABEL"
elif (( rc == 2 )); then
    fail "$LABEL" "jsonschema non installé"
else
    fail "$LABEL" "schéma a rejeté un log mono-fournisseur valide"
fi

# ── Case 6: Pre-built multi-provider log validates against schema ─────────────
# Three providers, provider="multi" at session level, provider/model per iteration.

LABEL="log multi-fournisseur → schéma valide"
MULTI_LOG="${TMPDIR_TEST}/multi-log.json"
python3 - "$MULTI_LOG" <<'PY'
import hashlib, json, sys, uuid
from datetime import datetime, timezone
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
def h(s): return hashlib.sha256(s.encode()).hexdigest()
its = [
    {"seq": 1, "action": "generate", "input_hash": h("p1"), "output_hash": h("r1"),
     "ts": now, "provider": "anthropic", "model": "claude-haiku-4-5-20251001"},
    {"seq": 2, "action": "generate", "input_hash": h("p2"), "output_hash": h("r2"),
     "ts": now, "provider": "openai",    "model": "gpt-4o-mini"},
    {"seq": 3, "action": "generate", "input_hash": h("p3"), "output_hash": h("r3"),
     "ts": now, "provider": "gemini",    "model": "gemini-2.5-flash-lite"},
]
concat = "".join(it["input_hash"] + it["output_hash"] for it in its)
log = {
    "session_id":        str(uuid.uuid4()),
    "provider":          "multi",
    "source_class":      "native",
    "attestation_class": "post-session",
    "started_at":        now,
    "ended_at":          now,
    "iterations":        its,
    "session_hash":      hashlib.sha256(concat.encode()).hexdigest(),
}
json.dump(log, open(sys.argv[1], "w"), indent=2)
PY
rc=0; py_validate "$SCHEMA" "$MULTI_LOG" > /dev/null 2>&1 || rc=$?
if (( rc == 0 )); then
    pass "$LABEL"
elif (( rc == 2 )); then
    fail "$LABEL" "jsonschema non installé"
else
    fail "$LABEL" "schéma a rejeté un log multi-fournisseur valide"
fi

# ── Case 7: Malformed log is rejected by schema validation ────────────────────
# input_hash is 63 chars instead of 64 — must fail pattern ^[0-9a-f]{64}$.
# Proves the schema actually catches invalid logs, not just passes everything.

LABEL="log malformé (input_hash 63 chars) → rejeté par le schéma"
BAD_LOG="${TMPDIR_TEST}/bad-log.json"
python3 - "$BAD_LOG" <<'PY'
import json, sys, uuid
from datetime import datetime, timezone
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
bad_hash = "a" * 63  # 63 chars — violates pattern ^[0-9a-f]{64}$
log = {
    "session_id":        str(uuid.uuid4()),
    "provider":          "anthropic",
    "model":             "claude-haiku-4-5-20251001",
    "source_class":      "native",
    "attestation_class": "post-session",
    "started_at":        now,
    "ended_at":          now,
    "iterations":        [{"seq": 1, "action": "generate",
                           "input_hash": bad_hash, "output_hash": bad_hash, "ts": now}],
    "session_hash":      "b" * 64,
}
json.dump(log, open(sys.argv[1], "w"), indent=2)
PY
rc=0; py_validate "$SCHEMA" "$BAD_LOG" > /dev/null 2>&1 || rc=$?
if (( rc == 1 )); then
    pass "$LABEL"
elif (( rc == 2 )); then
    fail "$LABEL" "jsonschema non installé"
else
    fail "$LABEL" "le schéma aurait dû rejeter un hash de 63 chars mais a validé"
fi

# ── Summary ────────────────────────────────────────────────────────────────────

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
