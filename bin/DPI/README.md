# Scripts spécifiques DPI

Placer ici les scripts spécifiques de collecte d'informations de la plateforme.
Aucun script de ce répertoire n'est exécuté automatiquement par
`checkplateforme.sh` ou `checkflux.sh` : lancer explicitement le script souhaité.

Utiliser Bash et les commandes déjà présentes sur RHEL minimal, privilégier les
collectes en lecture seule et documenter les éventuels prérequis de chaque script.
Ne pas stocker de mots de passe, clés privées ou rapports contenant des secrets ici.

## Processus Java en cours

`checkjava.sh` est un script autonome de collecte en lecture seule. Il lit `/proc`
et n'utilise ni JDK, ni `jps`, ni `jcmd`. Aucune installation ni élévation automatique
des droits n'est effectuée.

```bash
bash bin/DPI/checkjava.sh --localhost --json java-local.json
bash bin/DPI/checkjava.sh --inventory examples/serveurs.csv --json java-parc.json
```

Le même inventaire `host;user;port` et les mêmes règles SSH s'appliquent.
Les résultats sont affichés dans la console et enregistrés par défaut dans
`rapport-java.json`. Le tableau `java_inventory` contient une entrée par cible,
avec son code de retour et les données collectées :

- horodatage UTC de début de collecte (`collected_at_utc`) ;
- nombre de processus détectés (`process_count`) et tableau `processes` ;
- PID, PID parent, UID et nom d'utilisateur si résolvable ;
- nom du processus, état Linux, mémoire résidente en kio et nombre de threads ;
- chemin de l'exécutable, s'il est accessible ;
- compteurs des entrées illisibles et des processus disparus pendant le relevé.

Les processus dont le nom est `java` ou `java.bin`, ou dont le chemin d'exécutable
se termine ainsi, sont retenus. Les applications embarquant une JVM dans un autre
exécutable ou utilisant un binaire Java renommé peuvent ne pas être détectées.
Ce n'est pas une liste des versions de Java installées.

Pour relever aussi les arguments de lancement, explicitement :

```bash
bash bin/DPI/checkjava.sh --inventory examples/serveurs.csv --include-command-line --json java-detail.json
```

Les arguments peuvent contenir des identifiants, mots de passe ou jetons : cette
option les écrit tels quels dans la console et le JSON. Par défaut, `arguments`
vaut `null`. Avec l'option, il contient un tableau préservant chaque argument.
Le script ne lit pas les variables d'environnement des processus.

Il s'agit d'un instantané des **processus visibles par le compte de collecte**,
dans son espace de PID. `hidepid`, les permissions et les conteneurs peuvent
masquer des processus : une liste vide n'affirme pas qu'aucune JVM n'existe sur
l'hôte entier. Un chemin d'exécutable inaccessible reste vide ; une mémoire
indisponible vaut `null`. Aucun `sudo` n'est lancé automatiquement.

Codes de retour : **0** collecte réalisée, même si aucun Java n'est visible ;
**2** collecte impossible ou partielle. Les résultats accessibles sont conservés
en cas de collecte partielle. Un processus disparu en cours de relevé est compté
séparément. Une erreur SSH n'empêche pas de traiter les serveurs suivants.
Le visualiseur HTML plateforme/flux ne lit pas encore ce format DPI.

## Export au format nodes.json

`checknodes.sh` est autonome et produit l'enveloppe documentaire suivante, avec
les clés et types du modèle nodes.json : `_id`, `id`, `nodes`, `appModules`,
`appServers`, `datasources`, `fluxes`, `info`, `jobs`, `licences`, `metadatas`,
`readme`, `referentiels`, `tablespaces`. Les collections applicatives restent
vides : elles ne peuvent pas être déduites d'une collecte système.

```bash
bash bin/DPI/checknodes.sh --localhost --json nodes-local.json
bash bin/DPI/checknodes.sh --inventory examples/serveurs.csv --json nodes-parc.json
```

Chaque entrée de `nodes` contient :

- `lastUpdate` : horodatage Unix de début de collecte ;
- `hostname`, `domain`, `fqdn` : identité locale et nom résolu ;
- `ip` : première adresse renvoyée par `hostname -I`, pas nécessairement l'adresse
  utilisée pour SSH ni celle de la route par défaut ;
- `system.nameOS` : noyau et architecture ; `versionRedHat` : contenu de
  `/etc/redhat-release` (sinon nom de l'OS) ; `versionJDK` : première ligne de
  version de Java accessible dans PATH, pas celle de chaque JVM active ;
- `system.upTime` : secondes depuis le démarrage, chaîne décimale ; `load` :
  charges à 1, 5 et 15 minutes, dans une chaîne ;
- `processes` : lignes `% mémoire, PID, utilisateur, commande`, pour les processus
  nommés `java` ou `java.bin` ;
- `cpu.model`, `nbProc`, `frqProc`, `bogomips` : chaînes ; fréquence en MHz et
  BogoMIPS du premier CPU fournissant ces informations dans `/proc/cpuinfo` ;
- `memory` : nombres en kio ; `memFree` est réellement libre, `memUsed` est
  estimé par `MemTotal - MemAvailable`, et `swapUsed = SwapTotal - SwapFree` ;
- `network` : interfaces avec `nom`, `tx`, `rx` (compteurs d'octets cumulés,
  sous forme de chaînes ; ce ne sont pas des débits) ;
- `disks` : `name`, `total`, `used`, `available`, `percentUsed`, `mount` ;
  capacités numériques en kio et pourcentage avec son symbole `%` ;
- `rpms` : tableau des paquets installés, collectés directement par le script,
  avec exactement `name`, `version`, `release`, `arch`, `size` et `group`.
  Le repli vers dpkg est automatique si RPM est absent ou échoue. Aucune liste
  de paquets n'est affichée dans la console. En cas d'échec des deux collectes,
  `rpms` reste vide et le script retourne 2, sans perdre les mesures système.


Par défaut, les chaînes `processes` contiennent le nom de commande sans ses
arguments. Pour obtenir les lignes de commande complètes comme dans le modèle :

```bash
bash bin/DPI/checknodes.sh --inventory examples/serveurs.csv --include-command-line --json nodes-detail.json
```

Les arguments sont alors exportés tels quels et peuvent contenir des secrets.
Les limites de visibilité et de détection des JVM dépendent du compte et des noms
de processus. Une absence de Java dans PATH donne `versionJDK: ""` ; une valeur
mémoire impossible à mesurer vaut `null` plutôt qu'un zéro inventé. Les chaînes
non disponibles restent vides.

Des identifiants neufs sont générés pour chaque document : `_id.$oid` est une
chaîne hexadécimale de 24 caractères et `id` un identifiant aléatoire de 40 caractères.
Ce dernier est un identifiant de document, pas une empreinte stable de plateforme.
Aucun identifiant du modèle utilisateur n'est réutilisé. Pour utiliser des valeurs
fournies par votre application :

```bash
bash bin/DPI/checknodes.sh --localhost --id mon-identifiant --oid 0123456789abcdef01234567 --json nodes-import.json
```

Les scripts n'insèrent rien dans une base de données. Toute mise à jour d'un
objet existant doit être gérée par votre application avec les identifiants voulus.

Prérequis RHEL usuels : Bash, `hostname`, `uname`, `df`, `ps` (procps-ng),
`timeout` (coreutils), `/proc` et `/sys`. Java est facultatif ; s'il est présent,
`java -version` est borné à 5 secondes (arrêt forcé une seconde plus tard).
Aucun paquet n'est installé, aucun sudo n'est lancé. Le script livré ne dépend
pas des autres scripts du dépôt. L'inventaire utilise toujours `;` et les mêmes
paramètres SSH. Les fichiers existants ne sont pas écrasés.

Code **0** : collecte réalisée ; **2** : au moins une collecte impossible ou
incomplète. Les nœuds partiellement collectés restent dans le rapport ; les cibles
inaccessibles sont omises et signalées en console. Pour conserver le schéma du
modèle, aucun champ d'erreur supplémentaire ni code global n'est inséré dans le
JSON : conserver également le code de retour et les diagnostics console.
Les objets `{}` de remplissage du modèle ne sont pas reproduits.
Le visualiseur autonome `visualizer/nodes.html` affiche ce format. Ouvrir le
HTML, puis sélectionner le JSON : synthèse par serveur avec jauges RAM/swap/disques,
puis détail système/CPU/mémoire, réseau et processus Java au clic sur son nom.
Recherche, filtre par serveur, retour à la synthèse et impression PDF sont disponibles. Aucun import ni
accès réseau n'est nécessaire. Les entrées `{}` du modèle sont ignorées.
Le visualiseur ne peut pas déduire les échecs ou les cibles omises depuis le JSON :
conserver les diagnostics console et le code retour du script.


## Paquets intégrés à nodes

La collecte des paquets est embarquée dans `checknodes.sh`, sans fichier shell
à importer. Chaque `nodes[].rpms` contient exactement :

- `name` : nom du paquet ;
- `version` : version, avec préfixe `epoch:` si l'epoch est non nul ;
- `release` : release RPM ou révision Debian ; vide pour une version Debian native ;
- `arch` : architecture ;
- `size` : taille installée en octets (entier) ;
- `group` : groupe RPM ou section Debian ; vide si inconnu.

RPM est interrogé en premier. En cas d'absence, d'erreur ou de liste vide/invalide,
le script utilise `dpkg-query` sans installer de paquet ni lancer de mise à jour.
Seuls les paquets à l'état `installed` sont retenus. `Installed-Size` est multiplié
par 1 024 pour obtenir des octets ; `Section` fournit le groupe Debian.
La version Debian est séparée à son dernier tiret sans perdre son epoch.

Une erreur des deux gestionnaires conserve le nœud système, laisse `rpms` vide
et contribue au code 2. Les listes partielles ne sont pas mélangées. La console
contient uniquement les compteurs et diagnostics, jamais les paquets détaillés.
Les versions et architectures multiples restent distinctes dans le JSON.

## Visualiseur nodes unifié

Livrer uniquement `visualizer/nodes.html` avec le JSON de `checknodes.sh`.
Le bandeau **Synthèse des serveurs / Packages** permet de lire les mesures et
la matrice des paquets dans le même fichier HTML autonome. Le détail du serveur
reste accessible depuis la synthèse et les en-têtes de la matrice ; le retour
conserve les filtres. L'impression PDF porte sur la vue actuellement affichée.

Une liste de paquets vide ou absente reste inconnue dans la matrice. « Non listé »
indique seulement qu'un paquet ne figure pas dans une liste fournie. Les erreurs
et nœuds omis ne peuvent pas être reconstitués depuis ce format sans statut :
conserver les diagnostics console. Les anciens rapports utilisant `architecture`
restent lisibles, avec taille et groupe affichés comme non renseignés.
