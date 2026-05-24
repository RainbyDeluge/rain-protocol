#!/usr/bin/env python3
"""RAIN Evidence Bundle CLI.

Usage:
    python3 rain_cli.py create --artwork <file> --output <dir> --purpose "<text>" [options]
"""

import argparse
import sys
from pathlib import Path

# Make the rain package importable when running from any directory.
sys.path.insert(0, str(Path(__file__).parent))

from rain.builder import create_bundle

REPO_ROOT = Path(__file__).resolve().parent.parent


def _parse_ai_tools(raw: str) -> list:
    return [t.strip() for t in raw.split(",") if t.strip()] if raw else []


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="rain",
        description="RAIN Evidence Bundle CLI — create cryptographically provable artwork bundles",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # ── rain create ───────────────────────────────────────────────────────────
    p = sub.add_parser("create", help="Create a new RAIN evidence bundle")

    p.add_argument("--artwork", required=True, type=Path,
                   help="Path to the artwork file to certify")
    p.add_argument("--output",  required=True, type=Path,
                   help="Output directory for the bundle (created if absent)")
    p.add_argument("--purpose", required=True,
                   help="Free-text creative intent (intent.purpose, ≤2000 chars)")

    p.add_argument("--human-role",
                   choices=["auteur", "superviseur", "validateur"],
                   default="auteur", dest="human_role",
                   help="Role of the human in the creation process (default: auteur)")
    p.add_argument("--ai-tools", default="", dest="ai_tools",
                   help="Comma-separated AI tools used, e.g. 'claude-opus-4-7,midjourney' (default: none)")
    p.add_argument("--intent-timing",
                   choices=["PRE", "POST_24H", "POST_LATE"],
                   default="PRE", dest="intent_timing",
                   help="When intent was declared relative to AI use (default: PRE)")
    p.add_argument("--disclosure",
                   choices=["private", "internal", "public"],
                   default="public",
                   help="Intended disclosure scope (default: public)")
    p.add_argument("--level", choices=["P1", "P2"], default="P1",
                   help="Proof level: P1=declarative, P2=signed (default: P1)")
    p.add_argument("--no-timestamp", action="store_true", dest="no_timestamp",
                   help="Skip RFC 3161 timestamping when using --level P2")

    args = parser.parse_args()

    # ── Validate inputs ───────────────────────────────────────────────────────
    artwork = args.artwork.resolve()
    if not artwork.exists():
        print(f"Error: artwork file not found: {artwork}", file=sys.stderr)
        sys.exit(1)

    ai_tools = _parse_ai_tools(args.ai_tools)
    output   = args.output.resolve()

    # ── Banner ────────────────────────────────────────────────────────────────
    print("RAIN Evidence Bundle — create")
    print(f"  artwork  : {artwork.name}")
    print(f"  output   : {output}")
    print(f"  level    : {args.level}", end="")
    if args.level == "P2":
        ts_label = "no (--no-timestamp)" if args.no_timestamp else "yes (freetsa.org RFC 3161)"
        print(f"  |  timestamp: {ts_label}", end="")
    print()
    if ai_tools:
        print(f"  ai-tools : {', '.join(ai_tools)}")
    print()

    # ── Build ─────────────────────────────────────────────────────────────────
    try:
        rc = create_bundle(
            artwork_path=artwork,
            output_dir=output,
            purpose=args.purpose,
            human_role=args.human_role,
            ai_tools=ai_tools,
            intent_timing=args.intent_timing,
            disclosure_scope=args.disclosure,
            level=args.level,
            no_timestamp=args.no_timestamp,
            repo_root=REPO_ROOT,
        )
    except RuntimeError as exc:
        print(f"\nError: {exc}", file=sys.stderr)
        sys.exit(1)
    except Exception as exc:
        print(f"\nUnexpected error: {exc}", file=sys.stderr)
        sys.exit(1)

    print()
    if rc == 0:
        print(f"Bundle ready: {output}")
    else:
        print(f"Bundle created but verify.sh returned exit {rc}.", file=sys.stderr)
    sys.exit(rc)


if __name__ == "__main__":
    main()
