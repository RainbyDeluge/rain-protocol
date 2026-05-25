# RAIN: Record of Authorship, Iterations & Narrative

RAIN est un protocole ouvert de certification du processus de création assistée par IA. Là où C2PA certifie l'origine d'un contenu (l'acte de naissance), RAIN certifie le processus et la contribution humaine qui y ont mené, sous forme d'une biographie vérifiable.

---

## Pourquoi

Le droit d'auteur 2026 et l'AI Act européen exigent de documenter le contrôle humain exercé sur les systèmes d'IA ; les outils actuels certifient des fichiers, pas des processus. RAIN comble ce manque : il produit un objet cryptographiquement scellé qui retrace chaque itération du processus de création, y compris les échanges avec plusieurs fournisseurs d'IA, sans jamais exposer le contenu en clair. RAIN est une couche d'audit au-dessus de C2PA, pas un concurrent : les deux sont complémentaires. Le verifier est un script Bash et une page HTML : quiconque peut vérifier un bundle hors ligne, sans dépendre d'un fournisseur ou d'un registre central.

---

## Ce que RAIN vérifie

**Trois garanties cryptographiques**

| Garantie | Mécanisme |
|---|---|
| Intégrité | Double empreinte SHA-256 + SHA3-256 sur chaque fichier du bundle |
| Authenticité | Signature Ed25519 du manifest + chaîne de certificats vérifiable |
| Antériorité | Horodatage RFC 3161 (jeton `.tsr`) liant le manifest à une heure attestée par une TSA |

**Trois niveaux de preuve**

- **P1 (déclaratif).** L'auteur déclare son processus ; le bundle contient intent, policy et hashes. Pas de signature cryptographique. Valeur probatoire : preuve de bonne foi.
- **P2 (signé).** Le manifest est signé Ed25519 par une clé RAIN, optionnellement horodaté RFC 3161. Valeur probatoire : falsification détectable.
- **P3 (souverain).** L'auteur apporte sa propre clé (BYOK/HYOK) ; RAIN ne voit que les hashes signés. Valeur probatoire maximale ; non encore implémenté en v0.

---

## Démarrage rapide

**Prérequis :** `bash`, `openssl`, `python3` (≥ 3.11), `pip install anthropic openai google-genai jsonschema`.

### 1. Générer la PKI de test

```bash
bash scripts/gen-ca.sh
```

Crée `pki/ca-key.pem`, `pki/ca-cert.pem`, `pki/signer-key.pem`, `pki/signer-cert.pem`.

### 2. Créer un bundle P2 signé et horodaté

```bash
cd rain-bundle-cli
python3 rain_cli.py create \
  --artwork    /chemin/vers/oeuvre.png \
  --output     ../mon-bundle \
  --purpose    "Illustration de couverture générée sous ma direction" \
  --human-role auteur \
  --ai-tools   "claude-opus-4-7,midjourney" \
  --level      P2
```

Sans `--no-timestamp`, le CLI contacte freetsa.org pour obtenir un horodatage RFC 3161. La commande se termine en appelant `verify.sh` automatiquement.

Options notables : `--disclosure [private|internal|public]`, `--intent-timing [PRE|POST_24H|POST_LATE]`, `--zip` (produit un `.zip` distributable), `--c2pa` (embarque un manifest C2PA dans l'image artwork).

### 3. Vérifier un bundle

```bash
# Dossier ou .zip, même résultat
bash scripts/verify.sh mon-bundle/
bash scripts/verify.sh RAIN-<bundle_id>.zip

# Sortie JSON pour intégration outillage
bash scripts/verify.sh --json mon-bundle/

# Codes de sortie : 0=VALID  1=INVALID  2=DOWNGRADE
```

### 4. Vérifier dans le navigateur

Ouvrez `web/verify.html` dans un navigateur moderne (aucun serveur requis). Glissez-déposez un dossier bundle ou un `.zip`. La vérification des hashes et de la signature Ed25519 s'effectue entièrement via WebCrypto ; aucun octet ne quitte la machine.

### 5. Capturer une session MALS multi-fournisseur

Créez un fichier `.env` à la racine avec vos clés :

```
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...
GEMINI_API_KEY=...
```

Créez un fichier de prompts (préfixe `provider:` optionnel par ligne) :

```
# prompts.txt
anthropic: Décris en deux phrases une ville flottante au-dessus des nuages.
openai: Propose un système politique adapté à son isolement.
gemini: Décris le drapeau de cette cité.
```

Lancez la capture :

```bash
cd rain-bundle-cli
python3 mals_cli.py capture \
  --prompts prompts.txt \
  --output  mals-log.json \
  --max-tokens 200
```

Le CLI affiche l'estimation de coût par fournisseur et demande confirmation avant tout appel API. Le log produit ne contient que des hashes SHA-256 : jamais de prompt ni de réponse en clair.

Intégrez ensuite le log dans un bundle :

```bash
python3 rain_cli.py create \
  --artwork  oeuvre.png \
  --output   mon-bundle \
  --purpose  "..." \
  --level    P2 \
  --mals     mals-log.json
```

### 6. Lancer la suite de tests

```bash
bash scripts/test-verify.sh
# 6 cas : valid-p1, valid-p2-ts, tampered-hash, downgrade-p2-nosig, tampered-sig, zip
```

---

## Architecture du dépôt

| Chemin | Contenu |
|---|---|
| `schemas/` | Schémas JSON Draft 2020-12 : `manifest`, `intent`, `policy`, `bundle-index`, `mals-log` |
| `scripts/` | Pipeline Bash : `gen-ca.sh`, `prepare-p2.sh`, `timestamp-bundle.sh`, `sign-bundle.sh`, `verify.sh`, `test-verify.sh`, `c2pa-embed.sh` |
| `rain-bundle-cli/` | CLI Python : `rain_cli.py` (bundles), `mals_cli.py` (capture MALS multi-fournisseur) |
| `web/` | `verify.html`, vérificateur WebCrypto hors ligne, sans serveur |
| `c2pa-bridge/` | Clé et certificat de signature C2PA, template de manifest avec assertion `rain.bundle` |
| `pki/` | PKI de test générée par `gen-ca.sh` (CA + signer Ed25519), à ne pas utiliser en production |
| `tsa/` | Certificats freetsa.org pour la vérification locale des jetons RFC 3161 |
| `test-vectors/` | Bundles de référence : `valid-p1`, `valid-p2-ts`, `tampered-hash`, `tampered-sig`, `downgrade-p2-nosig` |
| `docs/glossary.md` | Définitions normatives : anchor digest, SSOT, proof object, source_class, attestation_class |

---

## MALS : capture multi-fournisseur

Le log MALS (Model-Agnostic Log Schema) est le différenciateur de RAIN pour les processus complexes : un seul fichier JSON certifie une session traversant plusieurs fournisseurs d'IA (Anthropic, OpenAI, Gemini) dans l'ordre réel d'utilisation. Chaque itération enregistre le fournisseur et le modèle réels (tels que retournés par l'API), chaînés cryptographiquement via un `session_hash` qui est le SHA-256 de la concaténation ordonnée de tous les `input_hash + output_hash`. Le log est conforme RGPD par construction : ni prompt ni réponse n'est jamais persisté, uniquement des hashes. Le schéma est rétrocompatible entre sessions mono-fournisseur (champs `provider`/`model` au niveau session) et multi-fournisseur (`provider: "multi"` au niveau session, `provider`/`model` par itération).

---

## Pont C2PA

Lorsque l'option `--c2pa` est passée au CLI, RAIN embarque un manifest C2PA standard dans le fichier artwork (PNG ou JPEG) via `scripts/c2pa-embed.sh`. Ce manifest contient une assertion `rain.bundle` portant le `bundle_id` et le `proof_level` du bundle RAIN associé. L'image C2PA est un livrable distinct : elle n'est pas intégrée dans le bundle mais placée dans un dossier `distribuable/` adjacent. `verify.sh --c2pa <image>` croise les deux artefacts : si les identifiants divergent, la vérification passe en `DOWNGRADE (C2PA_MISMATCH)`.

---

## Limites de la v0 (assumées)

Ces limites sont connues et documentées. Elles n'affectent pas la logique cryptographique du protocole ; elles concernent l'ancrage dans des autorités reconnues.

- **CA auto-signée.** La CA générée par `gen-ca.sh` n'est pas ancrée dans un trust store reconnu (Mozilla, Apple, Microsoft). La chaîne `CA → signer` se vérifie avec `openssl verify -CAfile pki/ca-cert.pem`, mais elle ne sera pas acceptée automatiquement par des navigateurs ou des outils tiers. L'ancrage dans une CA qualifiée eIDAS est prévu pour la production.
- **TSA non qualifiée eIDAS.** Le service d'horodatage utilisé (freetsa.org) délivre des jetons RFC 3161 techniquement conformes et vérifiables par `openssl ts`, mais sans valeur légale équivalente à un service qualifié. Les mêmes mécanismes s'appliquent à une TSA qualifiée ; seul l'ancrage change.
- **P3 non implémenté.** Le niveau souverain (BYOK/HYOK) est défini dans le schéma et le glossaire ; son pipeline de capture n'est pas encore livré.
- **Confiance API pour MALS.** En `attestation_class: post-session`, la fidélité entre les hashes du log et les échanges réels repose sur la bonne foi de l'implémentation cliente. Une `attestation_class: session-signed` (signature par itération en temps réel) est prévue pour P2 MALS.

---

## Modèle de confiance

Toute information nécessaire à la vérification vit soit dans l'objet signé (le manifest), soit dans une autorité externe vérifiable (TSA, CA), jamais dans un état non signé ou dans un registre propriétaire. Un bundle RAIN est un objet auto-contenu à ancrage externe attesté, au même titre qu'un commit Git signé ou une entrée dans un journal de transparence : sa validité est vérifiable par quiconque dispose des outils standards (`openssl`, `bash`, ou un navigateur moderne), sans aucune dépendance envers une infrastructure centralisée.

---

## Licence

Apache 2.0, voir [LICENSE](LICENSE).

Projet en développement actif. Les schémas, le format de bundle et les interfaces CLI peuvent évoluer avant la v1.0.
