#!/usr/bin/env bash
# RAIN Evidence Bundle Verifier v0.1.1
# Usage: verify.sh [--json] <bundle-dir|bundle.zip>
# Exit codes: 0=VALID  1=INVALID  2=DOWNGRADE

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
SCHEMAS_DIR="${REPO_ROOT}/schemas"

# ── Argument parsing ──────────────────────────────────────────────────────────

JSON_MODE=false
BUNDLE_DIR=""

for arg in "$@"; do
    case "$arg" in
        --json) JSON_MODE=true ;;
        -*)     printf 'Unknown option: %s\n' "$arg" >&2; exit 1 ;;
        *)      BUNDLE_DIR="$arg" ;;
    esac
done

if [[ -z "$BUNDLE_DIR" ]]; then
    printf 'Usage: %s [--json] <bundle-dir|bundle.zip>\n' "$(basename "$0")" >&2
    exit 1
fi

# ── Resolve input: directory or .zip ─────────────────────────────────────────
if [[ "$BUNDLE_DIR" == *.zip ]]; then
    # ZIP input: extract to a temp dir, clean up unconditionally on exit.
    if [[ ! -f "$BUNDLE_DIR" ]]; then
        printf 'Error: zip file not found: %s\n' "$BUNDLE_DIR" >&2
        exit 1
    fi
    _ZIP_ABS="$(cd "$(dirname "$BUNDLE_DIR")" && pwd)/$(basename "$BUNDLE_DIR")"
    _TMP_EXTRACT="$(mktemp -d)"
    trap 'rm -rf "$_TMP_EXTRACT"' EXIT
    [[ "$JSON_MODE" == false ]] && printf '[zip] Extracting %s…\n' "$(basename "$_ZIP_ABS")"
    python3 - "$_ZIP_ABS" "$_TMP_EXTRACT" <<'PY'
import zipfile, sys
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
PY
    # Handle flat zips (files at root) and single-subdir zips.
    if [[ -f "$_TMP_EXTRACT/bundle-index.json" ]]; then
        BUNDLE_DIR="$_TMP_EXTRACT"
    else
        _idx="$(find "$_TMP_EXTRACT" -maxdepth 2 -name 'bundle-index.json' 2>/dev/null | head -1)"
        BUNDLE_DIR="${_idx:+$(dirname "$_idx")}"
        BUNDLE_DIR="${BUNDLE_DIR:-$_TMP_EXTRACT}"
    fi
elif [[ -d "$BUNDLE_DIR" ]]; then
    BUNDLE_DIR="$(cd "$BUNDLE_DIR" && pwd)"
else
    printf 'Error: not found (expected a directory or a .zip file): %s\n' "$BUNDLE_DIR" >&2
    exit 1
fi

# ── State ─────────────────────────────────────────────────────────────────────

ERRORS=()
WARNINGS=()
DECLARED_LEVEL=""
EFFECTIVE_LEVEL="unknown"
FINAL_STATUS="VALID"
MANIFEST_FILE=""
TIMESTAMP_STATUS="absent"
TIMESTAMP_DATE=""

# ── Display helpers ───────────────────────────────────────────────────────────

_log()     { [[ "$JSON_MODE" == false ]] && printf '%s\n' "$*" || true; }
_section() { [[ "$JSON_MODE" == false ]] && printf '\n\033[1m[%s]\033[0m\n' "$*" || true; }
_ok()      { [[ "$JSON_MODE" == false ]] && printf '  \033[32m✓\033[0m %s\n' "$*" || true; }
_fail()    { [[ "$JSON_MODE" == false ]] && printf '  \033[31m✗\033[0m %s\n' "$*" || true; }
_warn()    { [[ "$JSON_MODE" == false ]] && printf '  \033[33m⚠\033[0m %s\n' "$*" || true; }
_info()    { [[ "$JSON_MODE" == false ]] && printf '  \033[90m→\033[0m %s\n' "$*" || true; }

add_error() {
    ERRORS+=("$1")
    FINAL_STATUS="INVALID"
    _fail "$1"
}

add_downgrade() {
    WARNINGS+=("$1")
    [[ "$FINAL_STATUS" != "INVALID" ]] && FINAL_STATUS="DOWNGRADE"
    _warn "$1"
}

# ── Python helpers ────────────────────────────────────────────────────────────

# Extract a top-level string field from a JSON file.
# Prints the value to stdout; exits 1 if key absent or file unreadable.
py_get_str() {
    python3 - "$1" "$2" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        val = json.load(f).get(sys.argv[2])
    if val is None: sys.exit(1)
    print(str(val))
except Exception:
    sys.exit(1)
PY
}

# Print one TSV line per entry in manifest.files[]: name TAB sha256 TAB sha3_256 TAB role
py_get_files() {
    python3 - "$1" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    for item in data.get('files', []):
        print('\t'.join([
            item.get('name',     ''),
            item.get('sha256',   ''),
            item.get('sha3_256', ''),
            item.get('role',     ''),
        ]))
except Exception as e:
    sys.stderr.write(f"Error reading files[]: {e}\n")
    sys.exit(1)
PY
}

# Compute SHA-256 and SHA3-256 of a file.
# Prints "sha256hex sha3_256hex" on one line.
py_hash() {
    python3 - "$1" <<'PY'
import hashlib, sys
try:
    data = open(sys.argv[1], 'rb').read()
    print(hashlib.sha256(data).hexdigest(), hashlib.sha3_256(data).hexdigest())
except Exception as e:
    sys.stderr.write(f"Error hashing {sys.argv[1]}: {e}\n")
    sys.exit(1)
PY
}

# Validate a JSON document against a JSON Schema file.
# Prints a detail line to stdout; exits 0=valid, 1=invalid.
# Uses jsonschema Draft202012Validator if available; structural fallback otherwise.
py_validate() {
    python3 - "$1" "$2" <<'PY'
import json, sys

doc_path, schema_path = sys.argv[1], sys.argv[2]

try:
    with open(doc_path)    as f: doc    = json.load(f)
    with open(schema_path) as f: schema = json.load(f)
except Exception as e:
    print(f"  parse error: {e}")
    sys.exit(1)

try:
    from jsonschema import Draft202012Validator
    v    = Draft202012Validator(schema)
    errs = sorted(v.iter_errors(doc), key=lambda e: list(e.path))
    if errs:
        for e in errs:
            path = '/'.join(str(p) for p in e.path) or '(root)'
            print(f"  - {path}: {e.message}")
        sys.exit(1)
    print("  (Draft 2020-12)")
except ImportError:
    # Structural fallback: check top-level required fields only
    required = schema.get('required', [])
    missing  = [k for k in required if k not in doc]
    if missing:
        for k in missing:
            print(f"  - missing required field '{k}'")
        sys.exit(1)
    print("  (jsonschema unavailable — structural check only)")
PY
}

# ── STEP 1: Structure ─────────────────────────────────────────────────────────
_section "STEP 1 — Structure"

STEP1_PASS=true
INDEX_FILE="${BUNDLE_DIR}/bundle-index.json"

if [[ ! -f "$INDEX_FILE" || ! -r "$INDEX_FILE" ]]; then
    add_error "STRUCTURE_MISSING: bundle-index.json"
    STEP1_PASS=false
else
    _ok "bundle-index.json found"

    # Resolve manifest_ref
    MANIFEST_REF=""
    MANIFEST_REF="$(py_get_str "$INDEX_FILE" "manifest_ref" 2>/dev/null)" || true

    if [[ -z "$MANIFEST_REF" ]]; then
        add_error "STRUCTURE_MISSING: manifest_ref absent from bundle-index.json"
        STEP1_PASS=false
    else
        MANIFEST_FILE="${BUNDLE_DIR}/${MANIFEST_REF}"

        if [[ ! -f "$MANIFEST_FILE" || ! -r "$MANIFEST_FILE" ]]; then
            add_error "STRUCTURE_MISSING: ${MANIFEST_REF}"
            STEP1_PASS=false
        else
            _ok "${MANIFEST_REF} found"

            # Check every file listed in manifest.files[]
            while IFS=$'\t' read -r fname _s256 _s3 _role; do
                [[ -z "$fname" ]] && continue
                if [[ ! -f "${BUNDLE_DIR}/${fname}" ]]; then
                    add_error "STRUCTURE_MISSING: ${fname}"
                    STEP1_PASS=false
                else
                    _ok "${fname} found"
                fi
            done < <(py_get_files "$MANIFEST_FILE")
        fi
    fi
fi

[[ "$STEP1_PASS" == true ]] && _ok "Structure check passed"

# ── STEP 2: Hashes ────────────────────────────────────────────────────────────
_section "STEP 2 — Hashes"

STEP2_PASS=false
if [[ "$STEP1_PASS" == true ]]; then
    STEP2_PASS=true

    while IFS=$'\t' read -r fname decl_sha256 decl_sha3 _role; do
        [[ -z "$fname" ]] && continue
        FPATH="${BUNDLE_DIR}/${fname}"

        actual=""
        actual="$(py_hash "$FPATH" 2>/dev/null)" || {
            add_error "HASH_MISMATCH: ${fname} (could not read file)"
            STEP2_PASS=false
            continue
        }

        actual_sha256="${actual%% *}"
        actual_sha3="${actual##* }"

        file_ok=true
        if [[ "$actual_sha256" != "$decl_sha256" ]]; then
            add_error "HASH_MISMATCH: ${fname} (sha256)"
            file_ok=false
            STEP2_PASS=false
        fi
        if [[ "$actual_sha3" != "$decl_sha3" ]]; then
            add_error "HASH_MISMATCH: ${fname} (sha3_256)"
            file_ok=false
            STEP2_PASS=false
        fi
        [[ "$file_ok" == true ]] && _ok "${fname} sha256+sha3_256 match"
    done < <(py_get_files "$MANIFEST_FILE")

    [[ "$STEP2_PASS" == true ]] && _ok "All hashes verified"
else
    _info "skipped — structure check failed"
fi

# ── STEP 3: Schema validation ─────────────────────────────────────────────────
_section "STEP 3 — Schemas"

STEP3_PASS=false

validate_doc() {
    local doc_file="$1" schema_file="$2" label="$3"
    local out=""
    local rc=0

    if [[ ! -f "$schema_file" ]]; then
        _warn "${label}: schema file not found at ${schema_file} — skipped"
        return 0
    fi

    out="$(py_validate "$doc_file" "$schema_file" 2>&1)" || rc=$?
    [[ -n "$out" ]] && _log "$out"
    if (( rc != 0 )); then
        add_error "SCHEMA_INVALID: ${label}"
        STEP3_PASS=false
    else
        _ok "${label} valid"
    fi
}

if [[ "$STEP2_PASS" == true ]]; then
    STEP3_PASS=true

    # Manifest — always validated
    validate_doc "$MANIFEST_FILE" "${SCHEMAS_DIR}/manifest.schema.json" "manifest.json"

    # Intent and policy — validated if referenced and present
    for ref_key in intent_ref policy_ref; do
        ref_val=""
        ref_val="$(py_get_str "$INDEX_FILE" "$ref_key" 2>/dev/null)" || true
        [[ -z "$ref_val" ]] && continue

        full_path="${BUNDLE_DIR}/${ref_val}"
        [[ ! -f "$full_path" ]] && continue

        case "$ref_key" in
            intent_ref) schema="${SCHEMAS_DIR}/intent.schema.json"  ;;
            policy_ref) schema="${SCHEMAS_DIR}/policy.schema.json"  ;;
        esac

        validate_doc "$full_path" "$schema" "$ref_val"
    done

    [[ "$STEP3_PASS" == true ]] && _ok "Schema validation passed"
else
    _info "skipped — hash check failed"
fi

# ── STEP 4: Proof level coherence ─────────────────────────────────────────────
_section "STEP 4 — Proof level"

if [[ "$STEP3_PASS" == true ]]; then
    DECLARED_LEVEL="$(py_get_str "$MANIFEST_FILE" "proof_level" 2>/dev/null)" || DECLARED_LEVEL="unknown"
    _ok "Declared level: ${DECLARED_LEVEL}"

    if [[ "$DECLARED_LEVEL" == "P2" || "$DECLARED_LEVEL" == "P3" ]]; then

        # ── 1. manifest.sig ────────────────────────────────────────────────
        _SIG_FILE="${BUNDLE_DIR}/manifest.sig"
        if [[ ! -f "$_SIG_FILE" ]]; then
            add_downgrade "PROOF_DOWNGRADE: declared ${DECLARED_LEVEL} but manifest.sig missing"
        else
            _ok "manifest.sig found"

            # ── 2. Certificate file (role=certificate in files[]) ──────────
            _CERT_FILE=""
            while IFS=$'\t' read -r fname _s256 _s3 role; do
                [[ -z "$fname" ]] && continue
                [[ "$role" == "certificate" ]] && { _CERT_FILE="${BUNDLE_DIR}/${fname}"; break; }
            done < <(py_get_files "$MANIFEST_FILE")

            if [[ -z "$_CERT_FILE" || ! -f "$_CERT_FILE" ]]; then
                add_downgrade "PROOF_DOWNGRADE: declared ${DECLARED_LEVEL} but signer certificate missing"
            else
                _ok "Signer certificate found: $(basename "$_CERT_FILE")"

                # ── 3. Cryptographic signature verification ────────────────
                _PUBKEY_TMP="$(mktemp)"
                _SIG_OK=false
                if openssl x509 -in "$_CERT_FILE" -pubkey -noout \
                       > "$_PUBKEY_TMP" 2>/dev/null && \
                   openssl pkeyutl -verify -pubin -inkey "$_PUBKEY_TMP" \
                       -rawin -in "$MANIFEST_FILE" -sigfile "$_SIG_FILE" \
                       > /dev/null 2>&1; then
                    _SIG_OK=true
                fi
                rm -f "$_PUBKEY_TMP"

                if [[ "$_SIG_OK" == true ]]; then
                    _ok "Ed25519 signature verified"
                else
                    add_error "SIGNATURE_INVALID: manifest signature does not verify"
                fi

                # ── 4. Fingerprint match ────────────────────────────────────
                _DECL_FP="$(py_get_str "$MANIFEST_FILE" "signer_cert_fingerprint" 2>/dev/null)" || _DECL_FP=""
                if [[ -n "$_DECL_FP" ]]; then
                    _ACTUAL_FP_RAW="$(openssl x509 -in "$_CERT_FILE" -noout \
                        -fingerprint -sha256 2>/dev/null || true)"
                    _ACTUAL_FP="${_ACTUAL_FP_RAW#*=}"     # strip "sha256 Fingerprint="
                    _ACTUAL_FP="${_ACTUAL_FP//:/}"         # strip colons
                    _ACTUAL_FP="$(printf '%s' "$_ACTUAL_FP" | tr '[:upper:]' '[:lower:]')"
                    if [[ "$_ACTUAL_FP" == "$_DECL_FP" ]]; then
                        _ok "signer_cert_fingerprint matches"
                    else
                        add_error "CERT_FINGERPRINT_MISMATCH: declared ${_DECL_FP}, actual ${_ACTUAL_FP}"
                    fi
                else
                    _warn "signer_cert_fingerprint absent from manifest — not checked"
                fi

                # ── 5. CA chain verification ────────────────────────────────
                # Downgrade (not INVALID): CA may legitimately be unavailable at verify time.
                _CA_CERT="${REPO_ROOT}/pki/ca-cert.pem"
                if [[ -f "$_CA_CERT" ]]; then
                    if openssl verify -CAfile "$_CA_CERT" "$_CERT_FILE" \
                           > /dev/null 2>&1; then
                        _ok "CA chain verified"
                    else
                        add_downgrade "CHAIN_UNTRUSTED: signer cert not signed by known CA"
                    fi
                else
                    _warn "CHAIN_UNVERIFIED: no CA available, signature authenticity not anchored"
                fi
            fi
        fi

    else
        _ok "P1 — no signature required"
    fi
else
    # Still try to read declared level for JSON output, even if steps failed
    if [[ -n "$MANIFEST_FILE" && -f "$MANIFEST_FILE" ]]; then
        DECLARED_LEVEL="$(py_get_str "$MANIFEST_FILE" "proof_level" 2>/dev/null)" || DECLARED_LEVEL="unknown"
    fi
    _info "skipped — prior steps failed"
fi

# ── STEP 5: Timestamp (RFC 3161) ──────────────────────────────────────────────
_section "STEP 5 — Timestamp (RFC 3161)"

if [[ "$STEP1_PASS" == true ]]; then

    # Locate entry with role=timestamp in manifest files[].
    _TSR_NAME=""
    while IFS=$'\t' read -r fname _s256 _s3 role; do
        [[ -z "$fname" ]] && continue
        [[ "$role" == "timestamp" ]] && { _TSR_NAME="$fname"; break; }
    done < <(py_get_files "$MANIFEST_FILE")

    if [[ -z "$_TSR_NAME" ]]; then
        # Timestamp is optional — absence is not an error.
        _info "no timestamp present"
        TIMESTAMP_STATUS="absent"
    else
        _TSR_FILE="${BUNDLE_DIR}/${_TSR_NAME}"

        # 1. Physical presence (declared but missing = integrity failure).
        if [[ ! -f "$_TSR_FILE" ]]; then
            add_error "TIMESTAMP_MISSING: declared in manifest but file absent (${_TSR_NAME})"
            TIMESTAMP_STATUS="invalid"
        else
            _ok "${_TSR_NAME} found"

            # 2. Anchor digest — read exclusively from the signed manifest (SSOT).
            #    SSOT principle: any information required for verification must live in
            #    the signed object (manifest.json) or an explicitly verified external
            #    authority (TSA), never in unsigned state like bundle-index.json.
            #    The Ed25519 signature verified in STEP 4 covers the full manifest
            #    including timestamp_anchor_sha256, so reading it from the manifest
            #    is equivalent to reading a signed claim.
            _TS_DIGEST=""
            _TS_DIGEST="$(py_get_str "$MANIFEST_FILE" "timestamp_anchor_sha256" 2>/dev/null)" || true

            if [[ -z "$_TS_DIGEST" ]]; then
                add_downgrade "TIMESTAMP_UNVERIFIABLE: no anchor digest in signed manifest"
                TIMESTAMP_STATUS="unverifiable"
            else
                _ok "Anchor digest (from signed manifest): ${_TS_DIGEST:0:16}…"

                # 3. TSA certificates — their absence is a warning, not a failure.
                _TSA_CA="${REPO_ROOT}/tsa/freetsa-cacert.pem"
                _TSA_CERT="${REPO_ROOT}/tsa/freetsa-tsa.crt"

                if [[ ! -f "$_TSA_CA" || ! -f "$_TSA_CERT" ]]; then
                    _warn "TIMESTAMP_UNANCHORED: TSA certs unavailable, timestamp not verified"
                    TIMESTAMP_STATUS="unverifiable"
                else
                    # 4. Cryptographic verification against the anchor digest from the manifest.
                    if openssl ts -verify \
                            -digest "${_TS_DIGEST}" \
                            -sha256 \
                            -in "${_TSR_FILE}" \
                            -CAfile "${_TSA_CA}" \
                            -untrusted "${_TSA_CERT}" \
                            > /dev/null 2>&1; then
                        _ok "RFC 3161 timestamp verified"
                        TIMESTAMP_STATUS="verified"
                        TIMESTAMP_DATE="$(openssl ts -reply -in "${_TSR_FILE}" -text 2>/dev/null \
                            | python3 -c "
import sys
for line in sys.stdin:
    if 'Time stamp:' in line:
        print(line.split('Time stamp:')[1].strip())
        break
" || true)"
                        [[ -n "$TIMESTAMP_DATE" ]] && _ok "Timestamp date: ${TIMESTAMP_DATE}"
                    else
                        add_error "TIMESTAMP_INVALID: token does not verify against anchor digest"
                        TIMESTAMP_STATUS="invalid"
                    fi
                fi
            fi
        fi
    fi

else
    _info "skipped — structure check failed"
fi

# ── Effective level ────────────────────────────────────────────────────────────

case "$FINAL_STATUS" in
    VALID)     EFFECTIVE_LEVEL="${DECLARED_LEVEL:-unknown}" ;;
    DOWNGRADE) EFFECTIVE_LEVEL="P1" ;;
    INVALID)   EFFECTIVE_LEVEL="unknown" ;;
esac

# ── Final output ───────────────────────────────────────────────────────────────

if [[ "$JSON_MODE" == true ]]; then
    {
        printf '%s\n' "$FINAL_STATUS"
        printf '%s\n' "${DECLARED_LEVEL:-}"
        printf '%s\n' "$EFFECTIVE_LEVEL"
        printf '%s\n' "${#ERRORS[@]}"
        (( ${#ERRORS[@]} > 0 ))   && printf '%s\n' "${ERRORS[@]}"   || true
        printf '%s\n' "${#WARNINGS[@]}"
        (( ${#WARNINGS[@]} > 0 )) && printf '%s\n' "${WARNINGS[@]}" || true
        printf '%s\n' "${TIMESTAMP_STATUS}"
        printf '%s\n' "${TIMESTAMP_DATE}"
    } | python3 -c "
import json, sys
lines = sys.stdin.read().splitlines()
i = 0
status    = lines[i]; i += 1
declared  = lines[i]; i += 1
effective = lines[i]; i += 1
ne        = int(lines[i]); i += 1
errors    = lines[i:i+ne]; i += ne
nw        = int(lines[i]); i += 1
warnings  = lines[i:i+nw]; i += nw
ts_status = lines[i]; i += 1
ts_date   = lines[i] if i < len(lines) else ''
out = {
    'status':           status,
    'declared_level':   declared,
    'effective_level':  effective,
    'errors':           errors,
    'warnings':         warnings,
    'timestamp_status': ts_status,
}
if ts_date:
    out['timestamp_date'] = ts_date
print(json.dumps(out, indent=2, ensure_ascii=False))
"
else
    printf '\n'
    case "$FINAL_STATUS" in
        VALID)
            printf '\033[32mRESULT: VALID [%s]\033[0m\n' "$EFFECTIVE_LEVEL"
            ;;
        DOWNGRADE)
            printf '\033[33mRESULT: DOWNGRADE (declared %s → effective %s)\033[0m\n' \
                "$DECLARED_LEVEL" "$EFFECTIVE_LEVEL"
            ;;
        INVALID)
            printf '\033[31mRESULT: INVALID\033[0m\n'
            ;;
    esac
fi

case "$FINAL_STATUS" in
    VALID)     exit 0 ;;
    DOWNGRADE) exit 2 ;;
    INVALID)   exit 1 ;;
esac
