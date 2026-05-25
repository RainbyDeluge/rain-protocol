#!/usr/bin/env python3
"""RAIN Evidence Bundle CLI.

Usage:
    python3 rain_cli.py create --artwork <file> --output <dir> --purpose "<text>" [options]
"""

import argparse
import subprocess
import sys
from pathlib import Path

# Make the rain package importable when running from any directory.
sys.path.insert(0, str(Path(__file__).parent))

from rain.builder import create_bundle, zip_bundle

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
    p.add_argument("--zip", action="store_true",
                   help="After building, produce RAIN-<bundle_id>.zip alongside the output directory")
    p.add_argument("--c2pa", action="store_true",
                   help="After building, embed a signed C2PA manifest into the artwork image "
                        "(PNG/JPEG only) and place the result in a distribuable/ folder alongside "
                        "the bundle.  Architecture option A: the C2PA image is a separate "
                        "deliverable whose rain.bundle assertion points back to this bundle.")

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
        if args.zip:
            import json as _json
            bundle_id = _json.loads((output / "manifest.json").read_text()).get("bundle_id", "bundle")
            zip_path = zip_bundle(output, bundle_id)
            print(f"  zip      : {zip_path}")

        # ── C2PA embedding (option A) ─────────────────────────────────────────
        # The bundle is complete and sealed before C2PA embedding starts.
        # The signed C2PA image is a separate deliverable: it carries a
        # rain.bundle assertion pointing to this bundle via bundle_id.
        # It is placed in a distribuable/ folder alongside the bundle dir,
        # not inside the bundle, to keep the two artefacts clearly distinct.
        if args.c2pa:
            _ext = artwork.suffix.lower()
            if _ext not in (".png", ".jpg", ".jpeg"):
                print(
                    f"\nWarning: --c2pa — C2PA embedding applies to PNG/JPEG only "
                    f"(artwork is {_ext or 'no extension'}); skipped.",
                    file=sys.stderr,
                )
            else:
                _c2pa_script = REPO_ROOT / "scripts" / "c2pa-embed.sh"
                print("\n── c2pa-embed.sh " + "─" * 43, flush=True)
                _embed_rc = subprocess.run(
                    ["bash", str(_c2pa_script), str(artwork), str(output)]
                ).returncode
                if _embed_rc == 0:
                    # c2pa-embed.sh writes <stem>-c2pa<ext> inside the bundle dir;
                    # move it to a sibling distribuable/ folder.
                    _c2pa_name = f"{artwork.stem}-c2pa{_ext}"
                    _c2pa_in_bundle = output / _c2pa_name
                    _distribuable_dir = output.parent / "distribuable"
                    _distribuable_dir.mkdir(exist_ok=True)
                    _c2pa_dest = _distribuable_dir / _c2pa_name
                    _c2pa_in_bundle.rename(_c2pa_dest)
                    print(f"\n  c2pa     : {_c2pa_dest}")
                else:
                    print(
                        f"\nWarning: c2pa-embed.sh exited {_embed_rc} — C2PA image not produced.",
                        file=sys.stderr,
                    )
    else:
        print(f"Bundle created but verify.sh returned exit {rc}.", file=sys.stderr)
    sys.exit(rc)


if __name__ == "__main__":
    main()
