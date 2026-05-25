"""MALS Session Capture — multi-provider session capture producing a compliant mals-log.

CONTRAINTE DE CONFIDENTIALITÉ (normative, reflète schemas/mals-log.schema.json) :
  - Aucun prompt en clair ni réponse en clair n'est jamais écrit sur disque.
  - Seuls input_hash et output_hash (SHA-256 hex) sont persistés.
  - Les clés API ne sont JAMAIS affichées, loguées ni incluses dans la sortie.

Format du fichier de prompts :
  Chaque ligne non vide et non commentée (#) est une itération.
  Préfixe optionnel 'provider: ' pour cibler un fournisseur précis :
    anthropic: Décris une ville flottante.
    openai: Ajoute un système politique.
    gemini: Décris son drapeau.
  Sans préfixe, utilise le --default-provider (défaut : anthropic).
"""

from __future__ import annotations

import hashlib
import json
import os
import sys
import uuid
from abc import ABC, abstractmethod
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_DOT_ENV = REPO_ROOT / ".env"

MAX_ITERATIONS = 10
DEFAULT_PROVIDER = "anthropic"
DEFAULT_MAX_TOKENS = 300

DEFAULT_MODELS: dict[str, str] = {
    "anthropic": "claude-haiku-4-5-20251001",
    "openai":    "gpt-4o-mini",
    "gemini":    "gemini-2.5-flash-lite",
}

# Kept for backward compat with importers that use DEFAULT_MODEL
DEFAULT_MODEL = DEFAULT_MODELS["anthropic"]

# Tarifs estimatifs en USD / 1 M tokens
_PRICING: dict[str, dict[str, float]] = {
    "claude-haiku-4-5-20251001": {"input": 0.80,  "output": 4.00},
    "claude-haiku-4-5":          {"input": 0.80,  "output": 4.00},
    "claude-sonnet-4-6":         {"input": 3.00,  "output": 15.00},
    "claude-opus-4-7":           {"input": 15.00, "output": 75.00},
    "gpt-4o-mini":               {"input": 0.15,  "output": 0.60},
    "gpt-4o-mini-2024-07-18":    {"input": 0.15,  "output": 0.60},
    "gemini-2.5-flash-lite":     {"input": 0.10,  "output": 0.40},
    "gemini-2.0-flash-lite":     {"input": 0.075, "output": 0.30},  # retiré, conservé pour logs existants
    "gemini-1.5-flash":          {"input": 0.075, "output": 0.30},
}
_DEFAULT_PRICING = {"input": 1.00, "output": 5.00}


# ── dotenv / key helpers ──────────────────────────────────────────────────────

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


def _require_env(var: str) -> str:
    """Retourne la valeur de la variable d'env. Lève RuntimeError si absente."""
    val = os.environ.get(var, "").strip()
    if not val:
        raise RuntimeError(
            f"{var} introuvable. Ajoutez-la dans .env ou exportez-la dans votre shell."
        )
    return val


# ── Hashing ───────────────────────────────────────────────────────────────────

def _sha256(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _session_hash(iterations: list[dict]) -> str:
    """SHA-256 de la concaténation ordonnée de tous les input_hash + output_hash."""
    concatenated = "".join(it["input_hash"] + it["output_hash"] for it in iterations)
    return hashlib.sha256(concatenated.encode("utf-8")).hexdigest()


# ── Provider abstraction ──────────────────────────────────────────────────────

class Provider(ABC):
    """Interface commune pour les adapteurs de fournisseurs d'IA."""

    provider_name: str  # identifiant court, ex. "anthropic"
    model: str          # modèle configuré, ex. "claude-haiku-4-5-20251001"

    @abstractmethod
    def generate(self, prompt: str, max_tokens: int) -> tuple[str, str, int, int]:
        """
        Appelle l'API avec un prompt unique.
        Retourne : (texte_réponse, modèle_réel, tokens_entrée, tokens_sortie).
        Les clés API sont chargées paresseusement au premier appel.
        Lève RuntimeError en cas d'échec API.
        """

    def pricing(self) -> dict[str, float]:
        return _PRICING.get(self.model, _DEFAULT_PRICING)


class AnthropicProvider(Provider):
    provider_name = "anthropic"

    def __init__(self, model: str = DEFAULT_MODELS["anthropic"]) -> None:
        self.model = model
        self._client = None

    def generate(self, prompt: str, max_tokens: int) -> tuple[str, str, int, int]:
        if self._client is None:
            _load_dotenv()
            import anthropic
            self._client = anthropic.Anthropic(api_key=_require_env("ANTHROPIC_API_KEY"))
        import anthropic as _ant
        try:
            resp = self._client.messages.create(
                model=self.model,
                max_tokens=max_tokens,
                messages=[{"role": "user", "content": prompt}],
            )
        except _ant.APIError as exc:
            raise RuntimeError(f"Anthropic API : {exc}") from exc
        text    = resp.content[0].text
        in_tok  = resp.usage.input_tokens  if resp.usage else 0
        out_tok = resp.usage.output_tokens if resp.usage else 0
        return text, resp.model, in_tok, out_tok


class OpenAIProvider(Provider):
    provider_name = "openai"

    def __init__(self, model: str = DEFAULT_MODELS["openai"]) -> None:
        self.model = model
        self._client = None

    def generate(self, prompt: str, max_tokens: int) -> tuple[str, str, int, int]:
        if self._client is None:
            _load_dotenv()
            import openai
            self._client = openai.OpenAI(api_key=_require_env("OPENAI_API_KEY"))
        import openai as _oai
        try:
            resp = self._client.chat.completions.create(
                model=self.model,
                max_tokens=max_tokens,
                messages=[{"role": "user", "content": prompt}],
            )
        except _oai.APIError as exc:
            raise RuntimeError(f"OpenAI API : {exc}") from exc
        text    = resp.choices[0].message.content or ""
        in_tok  = resp.usage.prompt_tokens     if resp.usage else 0
        out_tok = resp.usage.completion_tokens if resp.usage else 0
        return text, resp.model, in_tok, out_tok


class GeminiProvider(Provider):
    provider_name = "gemini"

    def __init__(self, model: str = DEFAULT_MODELS["gemini"]) -> None:
        self.model = model
        self._client = None

    def generate(self, prompt: str, max_tokens: int) -> tuple[str, str, int, int]:
        if self._client is None:
            _load_dotenv()
            from google import genai
            self._client = genai.Client(api_key=_require_env("GEMINI_API_KEY"))
        try:
            from google.genai import types as _gt
            resp = self._client.models.generate_content(
                model=self.model,
                contents=prompt,
                config=_gt.GenerateContentConfig(max_output_tokens=max_tokens),
            )
        except Exception as exc:
            raise RuntimeError(f"Gemini API : {exc}") from exc
        text    = resp.text or ""
        in_tok  = (resp.usage_metadata.prompt_token_count     if resp.usage_metadata else 0)
        out_tok = (resp.usage_metadata.candidates_token_count if resp.usage_metadata else 0)
        # Gemini doesn't echo the model ID in the response — use configured model
        return text, self.model, in_tok, out_tok


class StubProvider(Provider):
    """
    Provider de test — aucun appel API, aucune clé requise.
    Produit des réponses déterministes (SHA-256 du prompt tronqué).
    Usage : tests hors-ligne, CI sans clé API.

    Écrit TOUJOURS provider="stub" et model="stub-v1" dans le log.
    Il est interdit de se déguiser en un autre fournisseur : un log ne doit
    jamais affirmer qu'un appel anthropic/openai/gemini a eu lieu si c'était
    en réalité un stub.
    """
    provider_name = "stub"

    def __init__(self, model: str = "stub-v1") -> None:
        self.model = model

    def generate(self, prompt: str, max_tokens: int) -> tuple[str, str, int, int]:
        fake_text = f"[stub:{_sha256(prompt)[:24]}]"
        return fake_text, self.model, _est_tokens(prompt), 8

    def pricing(self) -> dict[str, float]:
        return {"input": 0.0, "output": 0.0}


PROVIDERS: dict[str, type[Provider]] = {
    "anthropic": AnthropicProvider,
    "openai":    OpenAIProvider,
    "gemini":    GeminiProvider,
    "stub":      StubProvider,
}


# ── Prompt file parsing ───────────────────────────────────────────────────────

def parse_prompts_file(
    path: Path,
    default_provider: str,
    max_iterations: int,
) -> list[tuple[str, str]]:
    """
    Parse le fichier de prompts en liste de (provider_name, texte_prompt).

    Format : chaque ligne peut commencer par 'provider: ' pour cibler un
    fournisseur précis. Sans préfixe, utilise default_provider.
    Les lignes vides et les commentaires (#) sont ignorés.
    """
    raw = [
        ln.strip()
        for ln in path.read_text(encoding="utf-8").splitlines()
        if ln.strip() and not ln.strip().startswith("#")
    ]
    if not raw:
        raise ValueError(f"Aucun prompt trouvé dans {path}")

    result: list[tuple[str, str]] = []
    for line in raw:
        provider = default_provider
        prompt   = line
        if ":" in line:
            prefix, _, rest = line.partition(":")
            candidate = prefix.strip().lower()
            if candidate in PROVIDERS:
                provider  = candidate
                prompt    = rest.strip()
        if prompt:
            result.append((provider, prompt))

    if len(result) > max_iterations:
        print(
            f"  [avert.] {len(result)} prompts trouvés ; limité à {max_iterations}",
            file=sys.stderr,
        )
        result = result[:max_iterations]

    return result


# ── Cost estimation ───────────────────────────────────────────────────────────

def _fmt_cost(usd: float) -> str:
    return "< $0.0001" if usd < 0.0001 else f"${usd:.6f}"


def _est_tokens(text: str) -> int:
    return max(1, len(text) // 4)


def estimate_multi_cost(
    parsed_prompts: list[tuple[str, str]],
    instances: dict[str, Provider],
    max_tokens: int,
) -> dict:
    """
    Estime le coût par fournisseur. Chaque appel est indépendant
    (pas de contexte croisé entre fournisseurs).
    """
    by_provider: dict[str, dict] = {}

    for pname, prompt in parsed_prompts:
        inst = instances[pname]
        pr   = inst.pricing()

        if pname not in by_provider:
            by_provider[pname] = {
                "model":             inst.model,
                "pricing":           pr,
                "count":             0,
                "est_input_tokens":  0,
                "est_output_tokens": 0,
                "est_cost_usd":      0.0,
            }

        in_tok  = _est_tokens(prompt)
        out_tok = max_tokens
        by_provider[pname]["count"]             += 1
        by_provider[pname]["est_input_tokens"]  += in_tok
        by_provider[pname]["est_output_tokens"] += out_tok
        by_provider[pname]["est_cost_usd"]      += (
            in_tok  / 1_000_000 * pr["input"]
            + out_tok / 1_000_000 * pr["output"]
        )

    total = sum(p["est_cost_usd"] for p in by_provider.values())
    return {"by_provider": by_provider, "total_est_cost_usd": total}


# ── Main capture function ─────────────────────────────────────────────────────

def capture_session(
    prompts_file: Path,
    output_file: Path,
    default_provider: str = DEFAULT_PROVIDER,
    provider_models: dict[str, str] | None = None,
    max_tokens: int = DEFAULT_MAX_TOKENS,
    max_iterations: int = MAX_ITERATIONS,
    schemas_dir: Path | None = None,
    skip_confirm: bool = False,
    stub_providers: set[str] | None = None,
) -> dict:
    """
    Mène une session multi-fournisseur et produit un mals-log conforme au schéma.

    provider_models : surcharges du modèle par fournisseur,
                      ex. {"anthropic": "claude-sonnet-4-6"}.
    stub_providers  : providers à remplacer par StubProvider honnête (provider="stub").
                      Utile pour les tests hors-ligne ou les clés sans quota.
                      Le log résultant reflètera "stub" — jamais un faux nom de provider.

    Invariants de confidentialité :
      - Aucun prompt ni réponse n'est écrit dans le log.
      - Les clés API ne sont jamais loguées ni affichées.
      - Le log ne contient que hashes, compteurs et métadonnées.
    """
    if schemas_dir is None:
        schemas_dir = REPO_ROOT / "schemas"

    stubs = stub_providers or set()

    # -- Résolution des instances provider -----------------------------------
    # Un provider stubé devient un vrai StubProvider (provider_name="stub"),
    # jamais un faux fournisseur : l'honnêteté du log l'exige.
    models = {**DEFAULT_MODELS, **(provider_models or {})}
    instances: dict[str, Provider] = {}
    for pname, cls in PROVIDERS.items():
        if pname in stubs:
            instances[pname] = StubProvider()
        else:
            instances[pname] = cls(models.get(pname, DEFAULT_MODELS.get(pname, "")))

    # -- Parse des prompts ----------------------------------------------------
    parsed = parse_prompts_file(prompts_file, default_provider, max_iterations)
    if not parsed:
        raise ValueError(f"Aucun prompt valide dans {prompts_file}")

    needed: set[str] = {pname for pname, _ in parsed}
    is_multi = len(needed) > 1

    # -- Estimation de coût --------------------------------------------------
    est = estimate_multi_cost(parsed, {k: instances[k] for k in needed}, max_tokens)

    print("\n── Coût estimé ──────────────────────────────────────────────────")
    for pname, pdata in est["by_provider"].items():
        pr = pdata["pricing"]
        print(
            f"  {pname:<12}: {pdata['count']} appel(s)  "
            f"modèle={pdata['model']}  "
            f"tarif=${pr['input']}/{pr['output']} MTok in/out"
            f"  → {_fmt_cost(pdata['est_cost_usd'])}"
        )
    print(f"  {'TOTAL':<12}: {_fmt_cost(est['total_est_cost_usd'])}")
    print()

    if not skip_confirm:
        try:
            answer = input("Lancer la session ? [o/N] ").strip().lower()
        except EOFError:
            answer = "n"
        if answer not in ("o", "oui", "y", "yes"):
            print("Session annulée.")
            sys.exit(0)

    # -- Vérification des clés API avant le premier appel --------------------
    _load_dotenv()
    _KEY_VARS = {
        "anthropic": "ANTHROPIC_API_KEY",
        "openai":    "OPENAI_API_KEY",
        "gemini":    "GEMINI_API_KEY",
    }
    missing = [
        f"  {_KEY_VARS[p]} (provider: {p})"
        for p in needed
        if p in _KEY_VARS and not os.environ.get(_KEY_VARS[p], "").strip()
    ]
    if missing:
        for m in missing:
            print(m, file=sys.stderr)
        raise RuntimeError("Clés API manquantes — session annulée.")

    # -- Exécution session ---------------------------------------------------
    session_id = str(uuid.uuid4())
    started_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    iterations:    list[dict] = []
    actual_models: dict[str, str] = {}
    token_use:     dict[str, list[int]] = {p: [0, 0] for p in needed}

    print()
    for seq, (pname, prompt) in enumerate(parsed, start=1):
        inst = instances[pname]
        print(f"[{seq}/{len(parsed)}] {pname}/{inst.model} …", flush=True)
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        text, actual_model, in_tok, out_tok = inst.generate(prompt, max_tokens)
        actual_models[pname] = actual_model
        token_use[pname][0] += in_tok
        token_use[pname][1] += out_tok

        if in_tok or out_tok:
            print(f"  tokens : in={in_tok}  out={out_tok}", flush=True)

        i_hash = _sha256(prompt)
        o_hash = _sha256(text)

        entry: dict = {
            "seq":         seq,
            "action":      "generate",
            "input_hash":  i_hash,
            "output_hash": o_hash,
            "ts":          ts,
        }
        if is_multi:
            entry["provider"] = inst.provider_name  # "stub" si stubé, vrai nom sinon
            entry["model"]    = actual_model

        iterations.append(entry)
        print(f"  input_hash  : {i_hash[:20]}…")
        print(f"  output_hash : {o_hash[:20]}…")

    ended_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # -- Construction du log -------------------------------------------------
    log: dict = {
        "session_id":        session_id,
        "source_class":      "native",
        "attestation_class": "post-session",
        "started_at":        started_at,
        "ended_at":          ended_at,
        "iterations":        iterations,
        "session_hash":      _session_hash(iterations),
    }

    if is_multi:
        log["provider"] = "multi"
        # Pas de model au niveau session pour les sessions multi-fournisseur
    else:
        sole = next(iter(needed))
        log["provider"] = sole
        log["model"]    = actual_models.get(sole, instances[sole].model)

    # -- Validation schéma ---------------------------------------------------
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

    # -- Écriture ------------------------------------------------------------
    output_file.parent.mkdir(parents=True, exist_ok=True)
    output_file.write_text(json.dumps(log, indent=2, ensure_ascii=False) + "\n")

    # -- Résumé --------------------------------------------------------------
    print("\n── Résumé ───────────────────────────────────────────────────────")
    print(f"  session_id   : {session_id}")
    actual_providers = sorted({instances[p].provider_name for p in needed})
    print(f"  fournisseurs : {', '.join(actual_providers)}")
    print(f"  itérations   : {len(iterations)}")
    print(f"  session_hash : {log['session_hash']}")
    total_actual = 0.0
    for pname, (in_t, out_t) in token_use.items():
        if in_t or out_t:
            mdl  = actual_models.get(pname, instances[pname].model)
            pr   = _PRICING.get(mdl, _DEFAULT_PRICING)
            cost = in_t / 1_000_000 * pr["input"] + out_t / 1_000_000 * pr["output"]
            total_actual += cost
            print(f"  {pname:<12}: in={in_t}  out={out_t}  → {_fmt_cost(cost)}")
    if total_actual:
        print(f"  coût réel    : {_fmt_cost(total_actual)}")
    print(f"  log écrit    : {output_file}")

    return log
