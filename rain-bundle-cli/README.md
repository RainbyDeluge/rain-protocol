# rain-bundle-cli

Command-line tool for creating RAIN Evidence Bundles.

## Prerequisites

- Python 3.9+
- OpenSSL 3 (for P2 signing and timestamping)
- `jsonschema` Python package (optional, enables schema validation): `pip install jsonschema`
- For **P2 bundles**: a PKI initialised with `bash scripts/gen-ca.sh` from the repo root
- For **P2 with timestamp**: TSA certificates installed with `bash scripts/get-tsa-cert.sh`

## Usage

Run from `rain-bundle-cli/` (or use absolute paths):

```bash
python3 rain_cli.py create \
  --artwork <file> \
  --output  <dir>  \
  --purpose "<text>" \
  [--human-role auteur|superviseur|validateur] \
  [--ai-tools   tool1,tool2] \
  [--intent-timing PRE|POST_24H|POST_LATE] \
  [--disclosure private|internal|public] \
  [--level P1|P2] \
  [--no-timestamp]
```

## Examples

### P1 — Declarative bundle (no cryptographic proof)

```bash
python3 rain_cli.py create \
  --artwork  ../test-vectors/valid-p1/artwork.txt \
  --output   /tmp/my-bundle-p1 \
  --purpose  "Texte écrit entièrement par un auteur humain, sans assistance IA." \
  --level    P1
```

### P2 — Signed + timestamped bundle (full canonical pipeline)

```bash
python3 rain_cli.py create \
  --artwork      ../test-vectors/valid-p1/artwork.txt \
  --output       /tmp/my-bundle-p2 \
  --purpose      "Texte écrit entièrement par un auteur humain, sans assistance IA." \
  --human-role   auteur \
  --intent-timing PRE \
  --disclosure   public \
  --level        P2
```

Runs `prepare-p2.sh → timestamp-bundle.sh (freetsa.org) → sign-bundle.sh` then verifies.

### P2 — Signed without timestamp

```bash
python3 rain_cli.py create \
  --artwork      ../test-vectors/valid-p1/artwork.txt \
  --output       /tmp/my-bundle-p2-nosig \
  --purpose      "Texte écrit entièrement par un auteur humain, sans assistance IA." \
  --level        P2 \
  --no-timestamp
```

### P2 — With declared AI tools

```bash
python3 rain_cli.py create \
  --artwork      my-image.png \
  --output       /tmp/my-bundle-ai \
  --purpose      "Illustration générée avec Midjourney, révisée et recadrée par l'auteur." \
  --human-role   superviseur \
  --ai-tools     "midjourney-v6,adobe-firefly" \
  --level        P2
```

## Pipeline canonique (P2)

```
prepare-p2.sh   → sets proof_level=P2, copies signer cert, computes fingerprint
timestamp-bundle.sh → obtains RFC 3161 token from freetsa.org, adds to files[]
sign-bundle.sh  → signs the finalised manifest with Ed25519 (seals timestamp too)
verify.sh       → validates structure, hashes, schema, signature, timestamp
```

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | VALID |
| 1 | INVALID |
| 2 | DOWNGRADE (declared level > effective level) |
