"""RAIN Evidence Bundle builder — core creation logic."""

import hashlib
import json
import shutil
import subprocess
import sys
import uuid
import zipfile
from datetime import datetime, timezone
from pathlib import Path

RAIN_VERSION = "0.1.0"


# ── Helpers ────────────────────────────────────────────────────────────────────

def _hashes(path: Path) -> tuple:
    """Return (sha256_hex, sha3_256_hex) for a file."""
    data = path.read_bytes()
    return hashlib.sha256(data).hexdigest(), hashlib.sha3_256(data).hexdigest()


def _write_json(path: Path, data: dict) -> None:
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")


def _validate(doc: dict, schema_name: str, schemas_dir: Path) -> None:
    """Validate doc against schema_name using jsonschema if available."""
    schema_path = schemas_dir / schema_name
    if not schema_path.exists():
        print(f"  [warn] schema not found: {schema_name} — skipping", file=sys.stderr)
        return
    try:
        from jsonschema import Draft202012Validator
        schema = json.loads(schema_path.read_text())
        errors = sorted(
            Draft202012Validator(schema).iter_errors(doc),
            key=lambda e: list(e.path),
        )
        if errors:
            for e in errors:
                loc = "/".join(str(p) for p in e.path) or "(root)"
                print(f"  [schema:{schema_name}] {loc}: {e.message}", file=sys.stderr)
            raise ValueError(f"Schema validation failed: {schema_name}")
    except ImportError:
        print(f"  [warn] jsonschema unavailable — skipping {schema_name}")


def _run_script(script: Path, bundle_dir: Path, label: str) -> None:
    """Run a shell script on bundle_dir; raise RuntimeError on non-zero exit."""
    print(f"\n── {label} " + "─" * max(1, 60 - len(label)), flush=True)
    rc = subprocess.run(["bash", str(script), str(bundle_dir)]).returncode
    if rc != 0:
        raise RuntimeError(f"{label} exited {rc} — see output above")


# ── Public API ─────────────────────────────────────────────────────────────────

def zip_bundle(output_dir: Path, bundle_id: str) -> Path:
    """Pack all files in output_dir into a flat RAIN-<bundle_id>.zip placed alongside it.

    Files are stored without a parent directory so that the zip root matches the
    bundle directory root — verify.sh can extract and verify without path adjustment.
    """
    zip_path = output_dir.parent / f"RAIN-{bundle_id}.zip"
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for f in sorted(output_dir.iterdir()):
            if f.is_file():
                zf.write(f, f.name)  # arcname = basename only → flat layout
    return zip_path


def create_bundle(
    *,
    artwork_path: Path,
    output_dir: Path,
    purpose: str,
    human_role: str,
    ai_tools: list,
    intent_timing: str,
    disclosure_scope: str,
    level: str,
    no_timestamp: bool,
    repo_root: Path,
) -> int:
    """
    Create a RAIN evidence bundle and return the exit code of verify.sh.

    The manifest is always initialised as P1 so that schema validation passes
    before signer_cert_fingerprint is known.  If level=="P2", the pipeline
    (prepare-p2.sh → [timestamp-bundle.sh] → sign-bundle.sh) upgrades it.
    """
    schemas_dir = repo_root / "schemas"
    scripts_dir = repo_root / "scripts"

    output_dir.mkdir(parents=True, exist_ok=True)

    # ── 1. Artwork ─────────────────────────────────────────────────────────────
    artwork_dest = output_dir / artwork_path.name
    shutil.copy2(artwork_path, artwork_dest)
    print(f"  copied  : {artwork_path.name}", flush=True)

    # ── 2. intent.json ─────────────────────────────────────────────────────────
    intent = {
        "purpose": purpose,
        "human_role": human_role,
        "ai_tools_used": ai_tools,
        "review_performed": True,
        "disclosure_scope": disclosure_scope,
        "intent_timing": intent_timing,
    }
    _validate(intent, "intent.schema.json", schemas_dir)
    _write_json(output_dir / "intent.json", intent)
    print("  created : intent.json", flush=True)

    # ── 3. policy.json ─────────────────────────────────────────────────────────
    policy = {
        "policy_id": "urn:rain:policy:default-v1",
        "version": "1.0.0",
        "hash_algorithms": ["SHA-256", "SHA3-256"],
    }
    _validate(policy, "policy.schema.json", schemas_dir)
    _write_json(output_dir / "policy.json", policy)
    print("  created : policy.json", flush=True)

    # ── 4. manifest.json ───────────────────────────────────────────────────────
    # Always written as P1 initially: signer_cert_fingerprint is not yet known.
    # prepare-p2.sh will upgrade proof_level to P2 and inject the fingerprint.
    files_entries = []
    for fname, role in [
        (artwork_path.name, "artwork"),
        ("intent.json",     "intent"),
        ("policy.json",     "policy"),
    ]:
        sha256, sha3_256 = _hashes(output_dir / fname)
        files_entries.append({"name": fname, "sha256": sha256, "sha3_256": sha3_256, "role": role})

    manifest = {
        "rain_version": RAIN_VERSION,
        "bundle_id":    str(uuid.uuid4()),
        "created_at":   datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "proof_level":  "P1",
        "files":        files_entries,
    }
    _validate(manifest, "manifest.schema.json", schemas_dir)
    _write_json(output_dir / "manifest.json", manifest)
    print("  created : manifest.json", flush=True)

    # ── 5. bundle-index.json ───────────────────────────────────────────────────
    index = {
        "manifest_ref": "manifest.json",
        "intent_ref":   "intent.json",
        "policy_ref":   "policy.json",
    }
    _validate(index, "bundle-index.schema.json", schemas_dir)
    _write_json(output_dir / "bundle-index.json", index)
    print("  created : bundle-index.json", flush=True)

    # ── 6. P2 pipeline ─────────────────────────────────────────────────────────
    if level == "P2":
        _run_script(scripts_dir / "prepare-p2.sh",      output_dir, "prepare-p2.sh")
        if not no_timestamp:
            _run_script(scripts_dir / "timestamp-bundle.sh", output_dir, "timestamp-bundle.sh")
        else:
            print("\n── timestamp-bundle.sh skipped (--no-timestamp) " + "─" * 13, flush=True)
        _run_script(scripts_dir / "sign-bundle.sh",     output_dir, "sign-bundle.sh")

    # ── 7. Verify ──────────────────────────────────────────────────────────────
    print("\n── verify.sh " + "─" * 48, flush=True)
    rc = subprocess.run(["bash", str(scripts_dir / "verify.sh"), str(output_dir)]).returncode
    return rc
