"""MALS Session Capture — appelle l'API Anthropic et produit un mals-log conforme.

CONTRAINTE DE CONFIDENTIALITÉ (normative, reflète schemas/mals-log.schema.json) :
  - Aucun prompt en clair ni réponse en clair n'est jamais écrit sur disque.
  - Seuls input_hash et output_hash (SHA-256 hex) sont persistés.
  - La clé API n'est JAMAIS affichée, loguée ni incluse dans la sortie.
"""

from __future__ import annotations

import hashlib
import json
import os
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    import anthropic as _anthropic_types  # noqa: F401 — type hints only

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_DOT_ENV = REPO_ROOT / ".env"

MAX_ITERATIONS = 5
DEFAULT_MODEL = "claude-haiku-4-5-20251001"
DEFAULT_MAX_TOKENS = 300

# Tarifs estimatifs en USD / 1 M tokens (usage interne à l'estimation pré-run)
_PRICING: dict[str, dict[str, float]] = {
    "claude-haiku-4-5-20251001": {"input": 0.80, "output": 4.00},
    "claude-haiku-4-5":          {"input": 0.80, "output": 4.00},
    "claude-sonnet-4-6":         {"input": 3.00, "output": 15.00},
    "claude-opus-4-7":           {"input": 15.00, "output": 75.00},
}
_DEFAULT_PRICING = {"input": 1.00, "output": 5.00}


# ── Sécurité clé API ──────────────────────────────────────────────────────────

def _load_dotenv() -> None:
    """Parse le .env à la racine du repo et injecte dans os.environ (sans écraser)."""
    if not _DOT_ENV.exists():
        return
    with open(_DOT_ENV, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            if key and key not in os.environ:
                os.environ[key] = value


def _get_api_key() -> str:
    """Retourne ANTHROPIC_API_KEY. Quitte avec message clair si absente."""
    _load_dotenv()
    key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    if not key:
        print(
            "\nErreur : ANTHROPIC_API_KEY introuvable.\n"
            "  Créez un fichier .env à la racine du repo :\n"
            "    ANTHROPIC_API_KEY=sk-ant-...\n"
            "  Ou exportez-la dans votre shell :\n"
            "    export ANTHROPIC_API_KEY=sk-ant-...",
            file=sys.stderr,
        )
        sys.exit(1)
    return key


# ── Hashing ───────────────────────────────────────────────────────────────────

def _sha256(text: str) -> str:
    """SHA-256 hex du texte encodé UTF-8."""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _session_hash(iterations: list[dict]) -> str:
    """SHA-256 de la concaténation ordonnée de tous les input_hash + output_hash."""
    concatenated = "".join(it["input_hash"] + it["output_hash"] for it in iterations)
    return hashlib.sha256(concatenated.encode("utf-8")).hexdigest()


# ── Estimation de coût ────────────────────────────────────────────────────────

def _est_tokens(text: str) -> int:
    """Estimation grossière : 1 token ≈ 4 caractères."""
    return max(1, len(text) // 4)


def estimate_cost(prompts: list[str], model: str, max_tokens: int) -> dict:
    """
    Estime le coût en USD d'une session multi-tour.

    Le contexte s'accumule à chaque appel (chaque prompt inclut l'historique
    complet des messages précédents). On approxime la longueur des réponses
    à max_tokens × 4 caractères pour la croissance du contexte.
    """
    pricing = _PRICING.get(model, _DEFAULT_PRICING)
    assumed_response_chars = max_tokens * 4  # approximation conservative

    total_input_tokens = 0
    total_output_tokens = 0
    context_chars = 0  # longueur cumulée de l'historique (user + assistant)

    for prompt in prompts:
        context_chars += len(prompt)
        total_input_tokens += _est_tokens(" " * context_chars)  # contexte complet
        total_output_tokens += max_tokens
        context_chars += assumed_response_chars  # la réponse va aussi dans le contexte

    cost_usd = (
        total_input_tokens  / 1_000_000 * pricing["input"]
        + total_output_tokens / 1_000_000 * pricing["output"]
    )
    return {
        "est_input_tokens":  total_input_tokens,
        "est_output_tokens": total_output_tokens,
        "est_cost_usd":      cost_usd,
        "pricing":           pricing,
    }


def _fmt_cost(usd: float) -> str:
    if usd < 0.0001:
        return f"< $0.0001"
    return f"${usd:.6f}"


# ── Capture principale ────────────────────────────────────────────────────────

def capture_session(
    prompts_file: Path,
    output_file: Path,
    model: str = DEFAULT_MODEL,
    max_tokens: int = DEFAULT_MAX_TOKENS,
    max_iterations: int = MAX_ITERATIONS,
    schemas_dir: Path | None = None,
    skip_confirm: bool = False,
) -> dict:
    """
    Mène une vraie session multi-tour avec l'API Anthropic et produit un mals-log.

    Invariants de confidentialité :
      - Aucun prompt ni réponse n'est écrit dans le log.
      - La clé API n'est jamais loguée ni affichée.
      - Le log ne contient que hashes, compteurs et métadonnées.

    Retourne le dict du log validé.
    """
    if schemas_dir is None:
        schemas_dir = REPO_ROOT / "schemas"

    # -- Lecture des prompts --------------------------------------------------
    raw_lines = [
        ln.strip()
        for ln in prompts_file.read_text(encoding="utf-8").splitlines()
        if ln.strip() and not ln.strip().startswith("#")
    ]
    if not raw_lines:
        raise ValueError(f"Aucun prompt trouvé dans {prompts_file}")

    prompts = raw_lines[:max_iterations]
    if len(raw_lines) > max_iterations:
        print(
            f"  [avert.] {len(raw_lines)} prompts trouvés ; limité à {max_iterations}",
            file=sys.stderr,
        )

    # -- Estimation de coût et confirmation -----------------------------------
    est = estimate_cost(prompts, model, max_tokens)
    print("\n── Coût estimé ──────────────────────────────────────────────────")
    print(f"  modèle          : {model}")
    print(f"  itérations      : {len(prompts)}")
    print(f"  tarif           : ${est['pricing']['input']}/MTok in  "
          f"${est['pricing']['output']}/MTok out")
    print(f"  tokens entrée   : ~{est['est_input_tokens']} (contexte cumulatif)")
    print(f"  tokens sortie   : ~{est['est_output_tokens']} max "
          f"(max_tokens={max_tokens} × {len(prompts)})")
    print(f"  coût estimé     : {_fmt_cost(est['est_cost_usd'])}")
    print()

    if not skip_confirm:
        try:
            answer = input("Lancer la session ? [o/N] ").strip().lower()
        except EOFError:
            answer = "n"
        if answer not in ("o", "oui", "y", "yes"):
            print("Session annulée.")
            sys.exit(0)

    # -- Session API ----------------------------------------------------------
    api_key = _get_api_key()

    import anthropic  # importé ici pour que le module reste importable sans SDK

    client = anthropic.Anthropic(api_key=api_key)

    session_id  = str(uuid.uuid4())
    started_at  = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    iterations:     list[dict] = []
    messages:       list[dict] = []  # historique conversationnel multi-tour
    actual_model    = model
    total_in_tok    = 0
    total_out_tok   = 0

    print()
    for seq, prompt in enumerate(prompts, start=1):
        print(f"[{seq}/{len(prompts)}] Appel API…", flush=True)
        messages.append({"role": "user", "content": prompt})
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        try:
            response = client.messages.create(
                model=model,
                max_tokens=max_tokens,
                messages=messages,
            )
        except anthropic.APIError as exc:
            raise RuntimeError(f"Erreur API Anthropic : {exc}") from exc

        assistant_text = response.content[0].text
        actual_model   = response.model

        if hasattr(response, "usage") and response.usage:
            in_tok  = response.usage.input_tokens
            out_tok = response.usage.output_tokens
            total_in_tok  += in_tok
            total_out_tok += out_tok
            print(f"  tokens : in={in_tok}  out={out_tok}", flush=True)

        # L'historique est maintenu pour le multi-tour — contenu jamais persisté
        messages.append({"role": "assistant", "content": assistant_text})

        # Seuls les hashes vont dans le log
        i_hash = _sha256(prompt)
        o_hash = _sha256(assistant_text)
        iterations.append({
            "seq":         seq,
            "action":      "generate",
            "input_hash":  i_hash,
            "output_hash": o_hash,
            "ts":          ts,
        })
        print(f"  input_hash  : {i_hash[:20]}…")
        print(f"  output_hash : {o_hash[:20]}…")

    ended_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # -- Construction du log (champs admis par le schéma uniquement) ----------
    log = {
        "session_id":       session_id,
        "provider":         "anthropic",
        "model":            actual_model,
        "source_class":     "native",
        "attestation_class": "post-session",
        "started_at":       started_at,
        "ended_at":         ended_at,
        "iterations":       iterations,
        "session_hash":     _session_hash(iterations),
    }

    # -- Validation schéma ----------------------------------------------------
    schema_path = schemas_dir / "mals-log.schema.json"
    if schema_path.exists():
        from jsonschema import Draft202012Validator
        schema = json.loads(schema_path.read_text())
        errors = sorted(
            Draft202012Validator(schema).iter_errors(log),
            key=lambda e: list(e.path),
        )
        if errors:
            for err in errors:
                loc = "/".join(str(p) for p in err.path) or "(root)"
                print(f"  [schema-err] {loc}: {err.message}", file=sys.stderr)
            raise ValueError("Le log produit ne valide pas contre mals-log.schema.json")
        print("\n  [schema] mals-log.schema.json : valide")
    else:
        print(f"\n  [avert.] schéma introuvable : {schema_path}", file=sys.stderr)

    # -- Écriture -------------------------------------------------------------
    output_file.parent.mkdir(parents=True, exist_ok=True)
    output_file.write_text(json.dumps(log, indent=2, ensure_ascii=False) + "\n")

    # -- Résumé ---------------------------------------------------------------
    print("\n── Résumé ───────────────────────────────────────────────────────")
    print(f"  session_id   : {session_id}")
    print(f"  modèle réel  : {actual_model}")
    print(f"  itérations   : {len(iterations)}")
    print(f"  session_hash : {log['session_hash']}")
    if total_in_tok:
        pricing = _PRICING.get(actual_model, _DEFAULT_PRICING)
        actual_cost = (
            total_in_tok  / 1_000_000 * pricing["input"]
            + total_out_tok / 1_000_000 * pricing["output"]
        )
        print(f"  tokens réels : in={total_in_tok}  out={total_out_tok}")
        print(f"  coût réel    : {_fmt_cost(actual_cost)}")
    print(f"  log écrit    : {output_file}")

    return log
