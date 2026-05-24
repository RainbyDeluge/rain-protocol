# RAIN — Glossaire normatif (v0.1.0)

Ce glossaire fait loi. En cas de divergence terminologique dans le reste
du dépôt, les définitions ci-dessous prévalent.

## Evidence Bundle
Fichier ZIP autonome contenant la preuve d'un processus de création.
Composants : manifest.json, intent.json, mals-sessions.json, les hashes
de l'artwork (SHA-256 + SHA3-256), un manifest C2PA, un timestamp RFC 3161,
une signature et son certificat, policy.json, et le script de vérification.

## Proof Level (niveau de preuve)
P1 — Déclaratif. L'auteur documente son processus sans preuve
cryptographique de session. Valide, mais confiance minimale.

P2 — Signé. SDK capturant et signant chaque étape en temps réel.
Preuve cryptographique de la session.

P3 — Souverain. Clés gérées par le client (BYOK/HYOK). RAIN ne voit
jamais le contenu, seulement un hash signé. Attestation produite côté client.

## Source class
Origine du log MALS. native (export direct API fournisseur) /
sdk (capturé par le SDK RAIN) / manual (import manuel).
Plafonne le Proof Level : manual = P1 max, sdk = P2 max, native = P3.

## Attestation class
Mode de scellement du log. post-session / session-signed / live.
Indépendante de la source class. Plafonne aussi le Proof Level.

## MALS (Model-Agnostic Log Schema)
Format ouvert de journal de session IA, agnostique au fournisseur.
Agrège les logs de plusieurs modèles dans un schéma unique, hashé par session.

## intent_timing
Moment de la déclaration d'intention. PRE (avant la première itération) /
POST_24H (après, dans les 24h) / POST_LATE (au-delà de 24h, plafonne à P1).

## DOWNGRADE
Bundle cohérent mais dont le niveau de preuve effectif est inférieur au
niveau déclaré. Exit code 2. N'est pas une erreur critique.

## Ce que RAIN ne prouve pas
La vérité, la légalité, l'originalité du contenu. RAIN produit un reçu
vérifiable et des signaux. Il prouve qu'une méthodologie documentée existe,
qu'elle est cohérente, et que toute incohérence est détectable.
