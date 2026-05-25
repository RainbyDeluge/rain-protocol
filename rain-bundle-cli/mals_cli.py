#!/usr/bin/env python3
"""MALS Session Capture CLI.

Usage:
    python3 mals_cli.py capture --prompts <fichier> [options]

La clé API Anthropic est lue depuis ANTHROPIC_API_KEY (variable d'environnement
ou fichier .env à la racine du repo). Elle n'est jamais affichée ni loguée.
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from rain.mals_capture import (
    DEFAULT_MAX_TOKENS,
    DEFAULT_MODEL,
    MAX_ITERATIONS,
    capture_session,
)

REPO_ROOT = Path(__file__).resolve().parent.parent


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="mals",
        description="MALS Session Capture — enregistre une session Anthropic réelle en mals-log",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # ── mals capture ──────────────────────────────────────────────────────────
    p = sub.add_parser(
        "capture",
        help="Capturer une session IA réelle et produire un mals-log signé",
    )
    p.add_argument(
        "--prompts", required=True, type=Path,
        help="Fichier texte : un prompt par ligne (lignes vides et # ignorés)",
    )
    p.add_argument(
        "--output", type=Path, default=None,
        help="Fichier de sortie JSON (défaut : mals-log.json dans le répertoire courant)",
    )
    p.add_argument(
        "--model", default=DEFAULT_MODEL,
        help=f"Modèle Anthropic (défaut : {DEFAULT_MODEL})",
    )
    p.add_argument(
        "--max-tokens", type=int, default=DEFAULT_MAX_TOKENS, dest="max_tokens",
        help=f"Tokens max par réponse (défaut : {DEFAULT_MAX_TOKENS})",
    )
    p.add_argument(
        "--max-iterations", type=int, default=MAX_ITERATIONS, dest="max_iterations",
        help=f"Nombre max d'itérations (défaut : {MAX_ITERATIONS})",
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

    print("MALS Session Capture")
    print(f"  prompts : {prompts_file}")
    print(f"  sortie  : {output_file}")

    try:
        capture_session(
            prompts_file=prompts_file,
            output_file=output_file,
            model=args.model,
            max_tokens=args.max_tokens,
            max_iterations=args.max_iterations,
            schemas_dir=REPO_ROOT / "schemas",
            skip_confirm=args.yes,
        )
    except (RuntimeError, ValueError) as exc:
        print(f"\nErreur : {exc}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nInterrompu.", file=sys.stderr)
        sys.exit(130)


if __name__ == "__main__":
    main()
