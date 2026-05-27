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
    p.add_argument("--level", choices=["P1", "P2", "P3"], default="P1",
                   help="Proof level: P1=declarative, P2=signed (RAIN key), P3=BYOK/HYOK (artist key) (default: P1)")
    p.add_argument("--no-timestamp", action="store_true", dest="no_timestamp",
                   help="Skip RFC 3161 timestamping when using --level P2 or P3")
    p.add_argument("--artist-key", type=Path, default=None, dest="artist_key", metavar="FILE",
                   help="[P3 uniquement] Chemin vers la clé privée Ed25519 de l'artiste (artist-key.pem). "
                        "HYOK : cette clé n'est jamais transmise à RAIN ; elle signe localement.")
    p.add_argument("--artist-cert", type=Path, default=None, dest="artist_cert", metavar="FILE",
                   help="[P3 uniquement] Chemin vers le certificat auto-signé de l'artiste (artist-cert.pem). "
                        "Ce fichier (clé publique uniquement) est intégré dans le bundle.")
    p.add_argument("--mals", type=Path, default=None, metavar="FILE",
                   help="Path to a MALS session log (JSON) to embed in the bundle. "
                        "Validated against mals-log.schema.json before integration; "
                        "added to files[] with role 'mals-log' and sealed with the rest.")
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
        print(f"Erreur : fichier artwork introuvable : {artwork}", file=sys.stderr)
        sys.exit(1)

    mals = args.mals.resolve() if args.mals else None
    if mals is not None and not mals.exists():
        print(f"Erreur : fichier MALS introuvable : {mals}", file=sys.stderr)
        sys.exit(1)

    # ── Validation des options P3 ─────────────────────────────────────────────
    artist_key  = args.artist_key.resolve()  if args.artist_key  else None
    artist_cert = args.artist_cert.resolve() if args.artist_cert else None

    if args.level == "P3":
        if artist_key is None or artist_cert is None:
            print(
                "Erreur : --level P3 requiert --artist-key <clé> et --artist-cert <cert>.\n"
                "  Générez une paire de clés artiste avec :\n"
                "    bash scripts/gen-artist-key.sh <nom> <dossier>",
                file=sys.stderr,
            )
            sys.exit(1)
        if not artist_key.exists():
            print(f"Erreur : clé artiste introuvable : {artist_key}", file=sys.stderr)
            sys.exit(1)
        if not artist_cert.exists():
            print(f"Erreur : certificat artiste introuvable : {artist_cert}", file=sys.stderr)
            sys.exit(1)
    else:
        if artist_key is not None or artist_cert is not None:
            print(
                "Avertissement : --artist-key et --artist-cert sont ignorés avec --level "
                f"{args.level} (P3 uniquement).",
                file=sys.stderr,
            )

    # M6 — --no-timestamp is only meaningful with --level P2 or P3.
    if args.no_timestamp and args.level not in ("P2", "P3"):
        print(
            "Avertissement : --no-timestamp sans effet avec --level P1 "
            "(l'horodatage RFC 3161 ne s'applique qu'aux bundles P2 et P3).",
            file=sys.stderr,
        )

    ai_tools = _parse_ai_tools(args.ai_tools)
    output   = args.output.resolve()

    # ── Banner ────────────────────────────────────────────────────────────────
    print("RAIN Evidence Bundle — create")
    print(f"  artwork  : {artwork.name}")
    print(f"  output   : {output}")
    print(f"  level    : {args.level}", end="")
    if args.level in ("P2", "P3"):
        ts_label = "no (--no-timestamp)" if args.no_timestamp else "yes (freetsa.org RFC 3161)"
        print(f"  |  timestamp: {ts_label}", end="")
    print()
    if args.level == "P3":
        print(f"  artist-key  : {artist_key}")
        print(f"  artist-cert : {artist_cert}")
        print("  [HYOK] la clé privée artiste n'est jamais transmise à RAIN")
    if ai_tools:
        print(f"  ai-tools : {', '.join(ai_tools)}")
    if mals:
        print(f"  mals     : {mals.name}")
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
            mals_path=mals,
            artist_key_path=artist_key,
            artist_cert_path=artist_cert,
        )
    except RuntimeError as exc:
        print(f"\nErreur : {exc}", file=sys.stderr)
        sys.exit(1)
    except Exception as exc:
        # m6 — affiche type + message pour les cas non prévus ; traceback complet
        # disponible via RAIN_DEBUG=1 sans polluer la sortie normale.
        print(
            f"\nErreur inattendue : {type(exc).__name__}: {exc}\n"
            f"  (définissez RAIN_DEBUG=1 pour le traceback complet)",
            file=sys.stderr,
        )
        if __import__("os").environ.get("RAIN_DEBUG"):
            import traceback
            traceback.print_exc()
        sys.exit(1)

    print()
    if rc == 0:
        print(f"Bundle ready: {output}")
        if args.zip:
            import json as _json
            # M9 — this read was outside the main try/except; a FileNotFoundError or
            # JSONDecodeError here would produce an unhandled traceback.
            try:
                bundle_id = _json.loads(
                    (output / "manifest.json").read_text()
                ).get("bundle_id", "bundle")
            except (FileNotFoundError, _json.JSONDecodeError) as _zip_err:
                print(
                    f"\nAvertissement : lecture de bundle_id impossible dans manifest.json "
                    f"— nom de zip 'bundle' utilisé ({_zip_err})",
                    file=sys.stderr,
                )
                bundle_id = "bundle"
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
                    f"\nAvertissement : --c2pa — l'intégration C2PA ne s'applique qu'aux PNG/JPEG "
                    f"(artwork : {_ext or 'aucune extension'}) ; ignoré.",
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
                    # C1 — wrap the rename in try/except: if c2pa-embed.sh exited 0
                    # but produced an unexpected output filename, rename() raises
                    # FileNotFoundError.  Without this guard the exception was
                    # unhandled (this block is outside the main try/except) and
                    # produced a raw Python traceback with no RAIN context.
                    try:
                        _distribuable_dir.mkdir(exist_ok=True)
                        _c2pa_dest = _distribuable_dir / _c2pa_name
                        _c2pa_in_bundle.rename(_c2pa_dest)
                        print(f"\n  c2pa     : {_c2pa_dest}")
                    except (FileNotFoundError, OSError) as _mv_err:
                        print(
                            f"\nAvertissement : image C2PA non déplacée — le bundle est valide, "
                            f"mais le livrable C2PA n'a pas pu être placé dans distribuable/.\n"
                            f"  Fichier attendu : {_c2pa_in_bundle}\n"
                            f"  Erreur          : {_mv_err}",
                            file=sys.stderr,
                        )
                else:
                    print(
                        f"\nAvertissement : c2pa-embed.sh a terminé avec le code {_embed_rc} — image C2PA non produite.",
                        file=sys.stderr,
                    )
    elif rc == 2:
        # C2 — exit 2 = DOWNGRADE: the bundle exists and is usable at P1 effective level,
        # but a declared proof attribute could not be fully verified (e.g. missing sig,
        # untrusted CA, absent timestamp).  This is NOT the same as INVALID.
        print(
            f"\nBundle built — DOWNGRADE: declared proof level could not be fully verified "
            f"(effective level P1). Run for details:\n"
            f"  bash scripts/verify.sh {output}",
            file=sys.stderr,
        )
    else:
        # exit 1 (or any unexpected non-zero) = INVALID: the bundle failed integrity checks.
        print(
            f"\nBundle INVALID — integrity check failed (verify.sh exited {rc}). "
            f"The bundle should not be distributed. Run for details:\n"
            f"  bash scripts/verify.sh {output}",
            file=sys.stderr,
        )
    sys.exit(rc)


if __name__ == "__main__":
    main()
