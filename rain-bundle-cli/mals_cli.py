#!/usr/bin/env python3
"""MALS Session Capture CLI — multi-provider.

Usage:
    python3 mals_cli.py capture --prompts <fichier> [options]

Format du fichier de prompts (multi-fournisseur) :
    # commentaire
    anthropic: Décris une ville flottante.
    openai: Ajoute un système politique.
    gemini: Décris son drapeau.
    Une ligne sans préfixe utilise --default-provider (défaut : anthropic).

Les clés API sont lues depuis ANTHROPIC_API_KEY / OPENAI_API_KEY / GEMINI_API_KEY
(variable d'environnement ou fichier .env à la racine du repo).
Elles ne sont jamais affichées ni loguées.
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from rain.mals_capture import (
    DEFAULT_MAX_TOKENS,
    DEFAULT_MODEL,          # backward compat
    DEFAULT_MODELS,
    DEFAULT_PROVIDER,
    MAX_ITERATIONS,
    PROVIDERS,
    capture_session,
)

REPO_ROOT = Path(__file__).resolve().parent.parent


def _positive_int(val: str) -> int:
    """M8 — argparse type for --max-tokens and --max-iterations.

    Rejects zero and negative values at parse time so the user gets a clear
    argparse error message rather than an obscure API rejection downstream.
    """
    try:
        n = int(val)
    except ValueError:
        raise argparse.ArgumentTypeError(f"expected a positive integer, got {val!r}")
    if n <= 0:
        raise argparse.ArgumentTypeError(f"must be > 0, got {n}")
    return n


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="mals",
        description=(
            "MALS Session Capture — enregistre une session IA réelle "
            "(mono ou multi-fournisseur) en mals-log"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # ── mals capture ──────────────────────────────────────────────────────────
    p = sub.add_parser(
        "capture",
        help="Capturer une session IA réelle et produire un mals-log signé",
    )
    p.add_argument(
        "--prompts", required=True, type=Path,
        help=(
            "Fichier texte de prompts. "
            "Format : une ligne par itération, avec préfixe 'provider: ' optionnel."
        ),
    )
    p.add_argument(
        "--output", type=Path, default=None,
        help="Fichier de sortie JSON (défaut : mals-log.json dans le répertoire courant)",
    )
    p.add_argument(
        "--default-provider",
        choices=list(PROVIDERS),
        default=DEFAULT_PROVIDER,
        dest="default_provider",
        help=f"Fournisseur utilisé pour les lignes sans préfixe (défaut : {DEFAULT_PROVIDER})",
    )
    p.add_argument(
        "--model", default=None,
        help=(
            "Modèle à utiliser pour le --default-provider "
            f"(défaut anthropic: {DEFAULT_MODELS['anthropic']}, "
            f"openai: {DEFAULT_MODELS['openai']}, "
            f"gemini: {DEFAULT_MODELS['gemini']})"
        ),
    )
    p.add_argument(
        "--anthropic-model", default=None, dest="anthropic_model",
        help=f"Modèle Anthropic (défaut : {DEFAULT_MODELS['anthropic']})",
    )
    p.add_argument(
        "--openai-model", default=None, dest="openai_model",
        help=f"Modèle OpenAI (défaut : {DEFAULT_MODELS['openai']})",
    )
    p.add_argument(
        "--gemini-model", default=None, dest="gemini_model",
        help=f"Modèle Gemini (défaut : {DEFAULT_MODELS['gemini']})",
    )
    p.add_argument(
        "--max-tokens", type=_positive_int, default=DEFAULT_MAX_TOKENS, dest="max_tokens",
        help=f"Tokens max par réponse, entier > 0 (défaut : {DEFAULT_MAX_TOKENS})",
    )
    p.add_argument(
        "--max-iterations", type=_positive_int, default=MAX_ITERATIONS, dest="max_iterations",
        help=f"Nombre max d'itérations, entier > 0 (défaut : {MAX_ITERATIONS})",
    )
    p.add_argument(
        "--stub-providers", default="", dest="stub_providers",
        metavar="PROVIDERS",
        help=(
            "Remplace les providers listés (virgule) par StubProvider "
            "(aucun appel API, aucune clé requise). "
            "Le nom du provider est conservé dans le log (model=stub-v1). "
            "Usage : tests hors-ligne ou clés sans quota. "
            "Ex. --stub-providers openai,gemini"
        ),
    )
    p.add_argument(
        "--attestation",
        choices=["post-session", "session-signed"],
        default="post-session",
        dest="attestation",
        help=(
            "Mode d'attestation du log. "
            "'post-session' (défaut) : hash signé après la session. "
            "'session-signed' : chaque itération est signée Ed25519 et chaînée "
            "en temps réel, avec ancrage TSA DigiCert non bloquant."
        ),
    )
    p.add_argument(
        "--yes", action="store_true",
        help="Sauter la confirmation de coût (mode non-interactif)",
    )

    args = parser.parse_args()

    # -- Validation des entrées -----------------------------------------------
    prompts_file = args.prompts.resolve()
    if not prompts_file.exists():
        print(f"Erreur : fichier de prompts introuvable : {prompts_file}", file=sys.stderr)
        sys.exit(1)

    output_file = args.output.resolve() if args.output else Path("mals-log.json").resolve()

    # Construire le dict de surcharges de modèles par provider
    provider_models: dict[str, str] = {}
    if args.anthropic_model:
        provider_models["anthropic"] = args.anthropic_model
    if args.openai_model:
        provider_models["openai"] = args.openai_model
    if args.gemini_model:
        provider_models["gemini"] = args.gemini_model
    # --model est un raccourci pour le default provider
    if args.model:
        provider_models[args.default_provider] = args.model

    stub_providers = {
        p.strip() for p in args.stub_providers.split(",") if p.strip()
    } if args.stub_providers else set()

    # M5 — validate stub provider names against the known PROVIDERS dict.
    # Previously an unknown name (e.g. --stub-providers foo) silently did nothing
    # or triggered an obscure downstream KeyError.
    if stub_providers:
        unknown = stub_providers - set(PROVIDERS)
        if unknown:
            print(
                f"Erreur : providers inconnus dans --stub-providers : {sorted(unknown)}\n"
                f"  Providers valides : {sorted(PROVIDERS)}",
                file=sys.stderr,
            )
            sys.exit(1)

    print("MALS Session Capture")
    print(f"  prompts          : {prompts_file}")
    print(f"  sortie           : {output_file}")
    print(f"  default-provider : {args.default_provider}")
    if provider_models:
        for pname, mdl in provider_models.items():
            print(f"  modèle {pname:<10}: {mdl}")
    if stub_providers:
        print(f"  stubs (no API)   : {', '.join(sorted(stub_providers))}")
    print(f"  attestation      : {args.attestation}")

    try:
        capture_session(
            prompts_file=prompts_file,
            output_file=output_file,
            default_provider=args.default_provider,
            provider_models=provider_models or None,
            max_tokens=args.max_tokens,
            max_iterations=args.max_iterations,
            schemas_dir=REPO_ROOT / "schemas",
            skip_confirm=args.yes,
            stub_providers=stub_providers,
            attestation_mode=args.attestation,
        )
    except (RuntimeError, ValueError) as exc:
        print(f"\nErreur : {exc}", file=sys.stderr)
        sys.exit(1)
    except (ImportError, ModuleNotFoundError) as exc:
        # C5 — SDK manquant (anthropic / openai / google-genai non installé).
        # Sans ce handler, Python affiche un traceback brut incompréhensible pour
        # un utilisateur qui n'a pas encore installé les dépendances.
        print(
            f"\nErreur : SDK manquant — {exc}\n"
            f"  Installez les dépendances : pip install -r requirements.txt\n"
            f"  Ou pour ce seul fournisseur : pip install {str(exc).split()[-1]}",
            file=sys.stderr,
        )
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nInterrompu.", file=sys.stderr)
        sys.exit(130)
    except Exception as exc:
        # C5 — filet de sécurité : toute exception non prévue (erreur réseau non
        # enveloppée dans les providers, bug interne…) affiche un message clair
        # au lieu d'un traceback brut.
        print(
            f"\nErreur inattendue : {type(exc).__name__}: {exc}\n"
            f"  (utilisez RAIN_DEBUG=1 pour le traceback complet)",
            file=sys.stderr,
        )
        if __import__("os").environ.get("RAIN_DEBUG"):
            import traceback
            traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
