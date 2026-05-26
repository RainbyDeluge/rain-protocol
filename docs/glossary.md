# RAIN — Glossaire normatif (v0.1.0)

Ce glossaire fait loi. En cas de divergence terminologique dans le reste
du dépôt, les définitions ci-dessous prévalent.

## Evidence Bundle
Fichier ZIP autonome contenant la preuve d'un processus de création.
Composants : manifest.json, intent.json, mals-sessions.json, les hashes
de l'artwork (SHA-256 + SHA3-256), un manifest C2PA, un timestamp RFC 3161,
une signature et son certificat, policy.json, et le script de vérification.

## Proof Level (niveau de preuve)
P1 — Déclaratif. L'auteur atteste son processus sans preuve
cryptographique de session. Attestation de bonne foi ; confiance minimale.

P2 — Signé. SDK capturant et signant chaque étape en temps réel.
Preuve cryptographique de la session.

P3 (BYOK/HYOK). Clés contrôlées par le client. RAIN ne voit
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

## Digest d'ancrage (timestamp_anchor_sha256)
Empreinte SHA-256 du manifest dans son état P2-ready, calculée avant
l'insertion de l'entrée du jeton d'horodatage. C'est une donnée historique
attestée : elle décrit un état passé du manifest et n'est pas recalculable
depuis le manifest final. Sa véracité repose sur deux attestations conjointes :
le jeton TSA, qui scelle exactement ce digest à une date donnée, et la
signature, qui couvre le manifest entier incluant ce champ. Le digest d'ancrage
vit exclusivement dans le manifest signé ; il n'est jamais stocké dans un
fichier non signé.

## Invariant SSOT (Single Source of Truth)
Toute information nécessaire à la vérification doit se trouver soit dans
l'objet signé (le manifest), soit dans une autorité externe explicitement
vérifiée (TSA, CA). Aucune donnée critique ne réside dans un état intermédiaire
local non signé tel que bundle-index.json. Cet invariant garantit qu'aucune
vérité parallèle non contrainte ne peut désynchroniser la preuve.

## Nature de l'objet de preuve
RAIN ne produit pas un objet entièrement auto-vérifiable par recalcul interne,
et ne le prétend pas. Il produit un objet auto-contenu à ancrage externe : un
conteneur qui porte son contenu, une assertion attestée sur son propre passé,
et la fermeture cryptographique de l'ensemble. Le système ne repose pas sur la
recomputation interne d'un état historique, mais sur l'attestation externe de
cet état, dont la trace est intégrée dans un objet signé fermant toutes les
dépendances. C'est le modèle de confiance standard des systèmes de
notarisation, des journaux de transparence et des chaînes de blocs.
