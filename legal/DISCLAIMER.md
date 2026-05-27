AVERTISSEMENT (DISCLAIMER) — Protocole RAIN


Préambule — Objet du présent avertissement

RAIN (Record of Authorship, Iterations & Narrative) est un protocole ouvert de certification du processus de création assistée par intelligence artificielle. 

Le protocole vise à produire un objet technique vérifiable permettant de documenter, préserver et attester l’intégrité d’un processus de création numérique, notamment lorsqu’il implique l’utilisation de modèles d’intelligence artificielle générative.

RAIN constitue une couche d’audit cryptographique du processus créatif. Il ne constitue ni une autorité publique, ni un organisme certificateur au sens réglementaire, ni un service de confiance qualifié au sens du règlement eIDAS.

Le présent avertissement définit la portée exacte de ce que RAIN atteste, et de ce que RAIN n'atteste pas.

Toute utilisation du protocole RAIN, de ses outils logiciels, de ses bundles, de ses schémas techniques ou de ses mécanismes de vérification implique l’acceptation pleine et entière des présentes dispositions.

Toute personne produisant, distribuant, transmettant, vérifiant ou exploitant un Evidence Bundle RAIN est réputée avoir pris connaissance des présentes limites et les accepter sans réserve.


Article 1 ~ Ce que RAIN atteste

Sous réserve du niveau de preuve effectivement atteint par un bundle donné (P1, P2, P3), RAIN permet d’établir, par des moyens cryptographiques vérifiables de manière indépendante :

1.1	L’intégrité des fichiers couverts par le manifeste. Toute modification affectant un fichier référencé dans le bundle devient détectable par vérification des empreintes cryptographiques SHA-256 et SHA3-256.

1.2	L’authenticité de la signature cryptographique, pour les niveaux P2 et P3. Le manifeste signé permet d’établir qu’une clé privée correspondant au certificat joint a signé le bundle et que celui-ci n’a pas été modifié postérieurement à cette signature.

1.3	L’antériorité technique d’un manifeste lorsqu’un horodatage RFC 3161 est présent. Dans cette hypothèse, le bundle existait nécessairement à la date attestée par l’autorité d’horodatage ayant émis le jeton de temps.

1.4	L’intégrité séquentielle d’un journal MALS lorsque celui-ci utilise une attestation de type session-signed. Les itérations enregistrées forment alors une chaîne cryptographique cohérente dont toute suppression, insertion, modification ou réorganisation devient détectable.

1.5	La cohérence interne d’un processus déclaré. RAIN permet de vérifier qu’un ensemble déterminé de fichiers, d’empreintes, de journaux et de métadonnées correspond bien au manifeste signé et horodaté auquel il se rattache.

1.6	La traçabilité technique d’un processus créatif numérique. En effet, elle s’applique lorsqu’une œuvre résulte d’interactions successives entre plusieurs systèmes d’intelligence artificielle, plusieurs modèles ou plusieurs opérateurs humains.

1.7	L’existence d’un état documentaire vérifiable à une date donnée. Cette garantie opère indépendamment de tout serveur centralisé ou de toute infrastructure propriétaire exploitée par l’éditeur du protocole.

Article 2 ~ Ce que RAIN n'atteste pas

RAIN est un instrument de preuve de processus et d'intégrité qui ne constitue en aucun cas :

2.1	Une garantie de véracité, d’exactitude ou de sincérité du contenu certifié. Un contenu faux, trompeur, manipulé, diffamatoire, illicite ou frauduleux peut demeurer techniquement valide au sens du protocole RAIN.

2.2	Une garantie de titularité des droits de propriété intellectuelle. RAIN ne démontre pas que le signataire disposait des droits nécessaires à l’utilisation, à l’exploitation, à la diffusion, à la reproduction et à la communication au public des contenus intégrés au bundle.

2.3	Une reconnaissance ou une garantie du caractère original d’une œuvre.

2.4	Une reconnaissance d’un apport créatif humain suffisant au sens des critères jurisprudentiels applicables à la protection des œuvres de l’esprit.

2.5	Une reconnaissance du caractère licite des données d’entraînement, modèles, corpus ou systèmes d’intelligence artificielle utilisés au cours du processus de création.

2.6	Une vérification de l’identité civile réelle du signataire. En version v0, l’existence d’une signature cryptographique n’implique pas qu’un tiers de confiance qualifié ait procédé à une vérification d’identité au sens réglementaire.

2.7	Une preuve de correspondance sémantique entre les prompts, les réponses générées et l’œuvre finale.

2.8	Le journal MALS n’enregistre que des empreintes cryptographiques. Il ne conserve pas le contenu en clair des prompts ou des réponses, sauf choix volontaire contraire de l’utilisateur.

2.9	Une garantie que le processus déclaré reflète fidèlement la réalité matérielle ou intellectuelle des échanges intervenus entre l’utilisateur et les modèles utilisés.

2.10	Une garantie de conformité réglementaire au regard du droit applicable aux systèmes d’intelligence artificielle, au droit de la propriété intellectuelle, au droit de la consommation, au droit des données personnelles ou à toute réglementation sectorielle.

2.11	Une reconnaissance officielle par une juridiction, une administration, une société de gestion collective, une maison de vente aux enchères, un éditeur, une plateforme ou une autorité publique.

2.12	Un mécanisme de certification de qualité artistique, de valeur culturelle, d’authenticité esthétique ou de légitimité critique.

2.13	Un système de notation ou de hiérarchisation des œuvres.

2.14	Le champ local_time est purement déclaratif. Il dépend de l’horloge locale de l’utilisateur et ne saurait constituer à lui seul une preuve d’antériorité.

2.15	RAIN n’atteste pas davantage qu’une œuvre a effectivement été créée sans intervention humaine significative, ni qu’elle résulte exclusivement d’une intelligence artificielle autonome. Le protocole documente un processus sans qualifier juridiquement la nature ontologique de l’auteur.

2.16	RAIN n’opère aucun contrôle éditorial préalable des contenus certifiés et n’exerce aucune surveillance générale des informations transitant par les outils ou formats compatibles avec le protocole.


Article 3 ~ Limites techniques et juridiques de la version v0

Les limitations suivantes sont connues, assumées et documentées.

Elles ne remettent pas en cause la logique cryptographique fondamentale du protocole, mais concernent l’environnement de confiance externe dans lequel celui-ci s’insère.

La version actuelle repose sur une autorité de certification auto-signée à des fins de développement et de démonstration. Cette autorité n’est ancrée dans aucun magasin de confiance public reconnu.

En conséquence, les certificats utilisés par défaut ne bénéficient pas de la présomption de fiabilité attachée aux services de confiance qualifiés au sens du règlement eIDAS.

La version v0 ne consulte ni liste de révocation de certificats (CRL), ni répondeur OCSP. Une clé compromise peut donc demeurer techniquement valide pour le vérificateur tant que son statut n’est pas contrôlé par un service externe.

Le niveau P3 est fondé sur un modèle BYOK/HYOK, dans lequel le client conserve le contrôle exclusif de ses clés cryptographiques. Il est défini conceptuellement mais non encore implémenté dans la version actuelle.

Les mécanismes MALS en mode post-session reposent partiellement sur la bonne foi de l’implémentation cliente concernant la fidélité des échanges réellement intervenus avec les fournisseurs de modèles.

Les services d’horodatage utilisés en environnement de démonstration peuvent ne pas constituer des services qualifiés au sens du règlement eIDAS.

La force probatoire effective d’un bundle dépendra notamment de la qualité de la chaîne de certification utilisée, de l’autorité d’horodatage retenue, des circonstances de création du bundle, des mesures de sécurité mises en œuvre par l’utilisateur et du contexte d’exploitation.

La compatibilité du protocole avec certains standards tiers, notamment C2PA, demeure susceptible d’évolution en fonction des modifications apportées par les consortiums, éditeurs ou autorités de normalisation concernés.

Le protocole étant open source et interopérable, des implémentations tierces non officielles peuvent exister. L’éditeur du protocole ne garantit ni leur conformité technique, ni leur sécurité, ni leur compatibilité avec les spécifications officielles.

Article 4 ~ Données personnelles et confidentialité

Le protocole RAIN est conçu selon un principe de minimisation des données.

Les journaux MALS n’ont pas été conçus pour stocker les prompts, réponses ou contenus en clair, mais uniquement des empreintes cryptographiques permettant de vérifier l’intégrité d’une séquence déclarée.

Toutefois, l’utilisateur demeure seul responsable des données qu’il choisit volontairement d’intégrer dans un bundle, dans les métadonnées, dans les fichiers joints ou dans les journaux de session.

L’utilisateur garantit disposer des droits, autorisations et bases légales nécessaires au traitement des données personnelles éventuellement incluses dans les bundles qu’il produit ou diffuse.

L’éditeur du protocole RAIN n’assume aucune responsabilité quant au contenu des bundles créés par des tiers.

Lorsque le protocole est utilisé dans un contexte soumis au règlement général sur la protection des données (RGPD), chaque acteur agit sous sa propre responsabilité quant à la qualification des traitements réalisés, à leur base légale, à leur durée de conservation et à l’exercice des droits des personnes concernées.

Article 5 ~ Absence de garantie et limitation de responsabilité

Le protocole RAIN, ses schémas, ses spécifications, son code source, ses outils logiciels, ses scripts, ses interfaces de vérification et ses mécanismes cryptographiques sont fournis « en l’état », sans garantie expresse ni implicite.

Aucune garantie n’est accordée quant à leur disponibilité, leur sécurité, leur conformité réglementaire, leur adéquation à un besoin particulier ou leur reconnaissance par des tiers.

RAIN constitue un protocole technique et non un service de conseil juridique, fiscal, réglementaire, patrimonial ou probatoire.

La création, la signature, la vérification ou la conservation d’un bundle ne saurait se substituer à une analyse juridique réalisée par un professionnel qualifié.

Dans les limites permises par le droit français applicable, les auteurs, contributeurs, mainteneurs, éditeurs et distributeurs du protocole RAIN excluent toute responsabilité directe, indirecte, accessoire, immatérielle ou consécutive résultant notamment :

-	D’une utilisation ou d’une impossibilité d’utilisation du protocole ;

-	D’une perte de données, de revenus, d’exploitation, d’opportunité commerciale ou de valeur économique ; 

-	D’une contestation relative à des droits de propriété intellectuelle ;

-	D’une compromission cryptographique, d’une erreur de configuration, d’une révocation de certificat ou d’une défaillance d’un tiers de confiance ;

-	D’une appréciation judiciaire ou administrative défavorable concernant la valeur probatoire d’un bundle.

Aucune stipulation du présent document ne saurait avoir pour effet d’exclure les responsabilités auxquelles il ne peut être légalement renoncé en application du droit français.



Article 6 ~ Usage probatoire

Un bundle RAIN constitue un élément technique susceptible d’être produit à titre d’élément de fait, de commencement de preuve ou de support documentaire dans le cadre d’une procédure amiable, arbitrale, administrative ou judiciaire.

Sa valeur probatoire relève exclusivement de l’appréciation souveraine des juridictions, autorités administratives, arbitres, experts ou organismes compétents saisis.

Le protocole RAIN ne crée par lui-même aucune présomption légale de titularité, d’authenticité artistique, d’originalité, de propriété ou de licéité.

La force probante d’un bundle dépend notamment du niveau de preuve atteint, de la robustesse de la chaîne cryptographique, de l’autorité d’horodatage utilisée, des mesures de sécurité mises en œuvre et des circonstances concrètes de production du bundle.

Le protocole RAIN doit être compris comme un mécanisme technique d’attestation susceptible de renforcer la traçabilité et l’intégrité d’un processus numérique, et non comme un substitut aux modes de preuve légalement organisés par le droit français.

Article 7 ~ Évolutivité du protocole 

Le protocole RAIN est un projet en développement actif.

Les spécifications techniques, schémas JSON, formats de bundle, mécanismes cryptographiques, modèles de preuve, politiques de signature, structures de gouvernance et interfaces logicielles sont susceptibles d’évolution avant la publication d’une version stable 1.0.

Chaque bundle comporte un identifiant de version permettant d’identifier l’état du protocole applicable lors de sa création.

La compatibilité ascendante entre versions ne peut être garantie de manière absolue.

Article 8 ~ Droit applicable et juridiction compétente

Le présent document est régi par le droit français.

Sous réserve des règles impératives applicables et des compétences exclusives éventuellement prévues par la loi, tout différend relatif à l’interprétation, la validité, l’exécution ou l’utilisation du protocole RAIN, de ses outils ou des présentes dispositions relèvera de la compétence exclusive des juridictions du ressort de la Cour d’appel de Paris.

Conclusion

RAIN est un protocole de traçabilité et d’intégrité du processus créatif à l’ère de l’intelligence artificielle.

Il ne prétend ni définir la création, ni résoudre les débats philosophiques, juridiques ou esthétiques liés à l’émergence des œuvres assistées par machine.

Il fournit un mécanisme technique destiné à rendre les processus plus vérifiables, plus auditables et plus lisibles.

Sa portée demeure celle d’un outil cryptographique documentant un processus donné à un instant donné, dans les limites techniques, juridiques et humaines rappelées aux présentes.
