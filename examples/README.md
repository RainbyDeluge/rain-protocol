# RAIN Examples

## deluge-genesis — *L'Émotion de l'IA*

**Auteur** : Le O  
**Œuvre** : `deluge-genesis/emotion-ia.png`  
**Date** : 27 mai 2026

### Description

*L'Émotion de l'IA* est une composition pixel-art minimaliste sur fond noir qui met en tension un cœur pixellisé minuscule (magenta #E91E8C, bas gauche) et un grand cerveau pixellisé dominant (cyan #00E5FF, droite). L'arrière-plan est traversé de lignes de code binaire déstructurées (or #FFB800). L'opposition taille/position — l'infime émotion contre l'immense calcul — représente la tension fondamentale de l'IA : sentir ou calculer ?

Palette Deluge : noir · magenta · or · cyan · blanc.

### Vérification en une commande

```bash
bash scripts/verify.sh examples/deluge-genesis/
```

Résultat attendu après `git clone`, sans aucune dépendance locale :

```
RESULT: VALID [P2]
```

> **Note honnête** : La chaîne CA RAIN apparaît non ancrée (`CHAIN_UNVERIFIED`) — la CA de test est auto-signée et non distribuée (comportement v0 attendu). L'intégrité des fichiers, la signature Ed25519, l'horodatage DigiCert RFC 3161 et la chaîne de processus session-signed sont, eux, pleinement vérifiés sans aucune dépendance locale.

### Preuves cryptographiques incluses

| Fichier | Rôle |
|---------|------|
| `manifest.json` | Manifeste signé Ed25519 (P2) |
| `manifest.sig` | Signature détachée |
| `manifest.tsr` | Jeton RFC 3161 DigiCert (27 mai 2026) |
| `signer-cert.pem` | Certificat signataire RAIN (clé publique uniquement) |
| `mals-4fbdfb85-*.json` | Log MALS session-signed — 2 itérations de conception OpenAI, chaîne Ed25519, ancrage DigiCert |
| `emotion-ia.png` | Œuvre originale (gpt-image-1, 1536×1024) |

Le log MALS capture la session de conception en `attestation_class: "session-signed"` : chaque itération est signée individuellement et chaînée, avec ancrage TSA DigiCert. Aucun prompt ni réponse n'est stocké — uniquement des hashes SHA-256.

### Image C2PA distribuable

```
examples/distribuable/emotion-ia-c2pa.png
```

Cette image contient un manifeste C2PA signé (`rain.bundle` assertion) pointant vers le `bundle_id` de ce bundle. Vérifiable avec `c2patool`.
