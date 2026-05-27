#!/usr/bin/env bash
# gen-artist-key.sh — Genere une paire de cles Ed25519 et un certificat auto-signe
# pour un artiste RAIN P3 (BYOK/HYOK).
#
# Usage: bash scripts/gen-artist-key.sh <nom-artiste> <dossier-sortie>
#
# Produit :
#   <dossier-sortie>/artist-key.pem   — Cle privee Ed25519 (CONFIDENTIELLE — ne jamais transmettre)
#   <dossier-sortie>/artist-cert.pem  — Certificat X.509 auto-signe (a fournir au SDK RAIN)
#
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  GARANTIE HYOK (Host Your Own Key)                                      ║
# ║                                                                          ║
# ║  La cle privee (artist-key.pem) NE DOIT JAMAIS etre transmise a RAIN.  ║
# ║  RAIN ne voit que le certificat (cle publique) et les hashes signes.   ║
# ║  La signature a lieu localement, sur votre machine.                     ║
# ╚══════════════════════════════════════════════════════════════════════════╝
#
# NOTE : ce script est intentionnellement SEPARE de pki/ (la PKI RAIN est
# reservee a P2 ; elle ne doit jamais contenir de cles artiste P3).

set -euo pipefail

# ── Arguments ─────────────────────────────────────────────────────────────────

if [[ $# -ne 2 ]]; then
    printf 'Usage: %s <nom-artiste> <dossier-sortie>\n' "$(basename "$0")" >&2
    printf '  Exemple: bash scripts/gen-artist-key.sh "Alice Martin" artist-keys/\n' >&2
    exit 1
fi

ARTIST_NAME="$1"
OUTPUT_DIR="$2"

if [[ -z "$ARTIST_NAME" ]]; then
    printf "Erreur : le nom de l'artiste ne peut pas etre vide.\n" >&2
    exit 1
fi

# ── Banniere HYOK ─────────────────────────────────────────────────────────────

printf '\n'
printf '╔══════════════════════════════════════════════════════════════════════╗\n'
printf '║  RAIN P3 — Generation de cle artiste (BYOK/HYOK)                    ║\n'
printf '╠══════════════════════════════════════════════════════════════════════╣\n'
printf "║  La cle privee generee NE DOIT JAMAIS etre transmise a RAIN.        ║\n"
printf "║  Conservez-la exclusivement sur votre machine, hors de tout depot.  ║\n"
printf "║  Seul le certificat (cle publique) est partage avec le SDK RAIN.    ║\n"
printf '╚══════════════════════════════════════════════════════════════════════╝\n'
printf '\n'

printf '  Artiste    : %s\n' "$ARTIST_NAME"
printf '  Dossier    : %s\n' "$OUTPUT_DIR"
printf '\n'

# ── Creation du dossier de sortie ─────────────────────────────────────────────

mkdir -p "$OUTPUT_DIR"

KEY_FILE="${OUTPUT_DIR}/artist-key.pem"
CERT_FILE="${OUTPUT_DIR}/artist-cert.pem"

# Verifier qu'on ne va pas ecrire dans pki/ (reserve a P2)
ABS_OUTPUT="$(cd "$OUTPUT_DIR" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PKI_DIR_ABS="${REPO_ROOT}/pki"
if [[ -d "${PKI_DIR_ABS}" ]]; then
    PKI_DIR_ABS="$(cd "${PKI_DIR_ABS}" && pwd)"
fi

if [[ "$ABS_OUTPUT" == "$PKI_DIR_ABS" || "$ABS_OUTPUT" == "${PKI_DIR_ABS}/"* ]]; then
    printf 'Erreur : le dossier de sortie (%s) est dans pki/.\n' "$OUTPUT_DIR" >&2
    printf '  La PKI RAIN est reservee a P2. Choisissez un dossier different,\n' >&2
    printf '  par exemple : artist-keys/ ou ~/mes-cles-rain/\n' >&2
    exit 1
fi

# ── Avertissement si les fichiers existent deja ───────────────────────────────

if [[ -f "$KEY_FILE" ]] || [[ -f "$CERT_FILE" ]]; then
    printf '[0/3] Fichiers existants detectes dans %s :\n' "$OUTPUT_DIR"
    [[ -f "$KEY_FILE"  ]] && printf '  artist-key.pem  — existant\n'
    [[ -f "$CERT_FILE" ]] && printf '  artist-cert.pem — existant\n'
    printf '  Ces fichiers seront REMPLACES.\n'
    printf '  Appuyez sur Entree pour continuer ou Ctrl+C pour annuler.\n'
    read -r _confirm || true
fi

# ── Etape 1 : Generer la cle privee Ed25519 ───────────────────────────────────

printf '[1/3] Generation de la cle privee Ed25519...\n'
openssl genpkey -algorithm ed25519 -out "$KEY_FILE" 2>/dev/null
chmod 600 "$KEY_FILE"
printf '  %-30s (chmod 600)\n' "artist-key.pem"

# ── Etape 2 : Creer un certificat auto-signe ──────────────────────────────────

printf '[2/3] Creation du certificat auto-signe...\n'

# Sanitize CN: remove characters that break the subject string
SAFE_CN="$(printf '%s' "$ARTIST_NAME" | tr -dc '[:alnum:] ._-')"

# Config minimale pour le certificat auto-signe
_CERT_CONF="$(mktemp /tmp/rain-artist-cert-XXXXXX.cnf)"
cat > "$_CERT_CONF" << CONFEOF
[req]
distinguished_name = dn
x509_extensions    = v3_artist
prompt             = no

[dn]
CN = ${SAFE_CN}
O  = RAIN P3 Artist (self-signed)
OU = BYOK/HYOK

[v3_artist]
keyUsage             = critical, digitalSignature
extendedKeyUsage     = emailProtection
basicConstraints     = CA:FALSE
subjectKeyIdentifier = hash
CONFEOF

openssl req -new -x509 \
    -key "$KEY_FILE" \
    -out "$CERT_FILE" \
    -days 1825 \
    -config "$_CERT_CONF" \
    2>/dev/null

rm -f "$_CERT_CONF"
printf '  %-30s (valide 5 ans, auto-signe)\n' "artist-cert.pem"

# ── Etape 3 : Afficher les informations du certificat ─────────────────────────

printf '[3/3] Informations du certificat :\n'
openssl x509 -in "$CERT_FILE" -noout \
    -subject -issuer -dates -fingerprint -sha256 2>/dev/null \
    | sed 's/^/  /'

# ── Resume et instructions ────────────────────────────────────────────────────

printf '\n'
printf '╔══════════════════════════════════════════════════════════════════════╗\n'
printf '║  Cle artiste generee avec succes                                     ║\n'
printf '╠══════════════════════════════════════════════════════════════════════╣\n'
printf "║  PRIVEE  → %s\n" "${KEY_FILE}"
printf "║           NE JAMAIS transmettre — NE JAMAIS committer dans git       ║\n"
printf '╠══════════════════════════════════════════════════════════════════════╣\n'
printf "║  PUBLIQUE → %s\n" "${CERT_FILE}"
printf "║             A fournir au SDK RAIN lors de la creation du bundle P3   ║\n"
printf '╚══════════════════════════════════════════════════════════════════════╝\n'
printf '\n'
printf '  Prochaine etape — creer un bundle P3 :\n'
printf '    cd rain-bundle-cli\n'
printf '    python3 rain_cli.py create \\\n'
printf '      --artwork  <oeuvre.png> \\\n'
printf '      --output   <mon-bundle> \\\n'
printf '      --purpose  "<intention creative>" \\\n'
printf '      --level    P3 \\\n'
printf '      --artist-key  %s \\\n' "$KEY_FILE"
printf '      --artist-cert %s\n' "$CERT_FILE"
printf '\n'
printf '  AVERTISSEMENT IDENTITAIRE :\n'
printf '    Le bundle P3 resultant sera signe cryptographiquement, mais le\n'
printf '    verificateur RAIN affichera IDENTITY_UNVERIFIED car aucune autorite\n'
printf '    de confiance (CA) ne confirme que ce certificat appartient a "%s".\n' "$ARTIST_NAME"
printf '    La signature prouve l'"'"'intention ; elle ne prouve pas l'"'"'identite.\n'
printf '\n'
