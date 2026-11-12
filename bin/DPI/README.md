# DPI(1)

## NOM

checknodes, checkjava — collecter les informations techniques d'une plateforme Linux.

## SYNOPSIS

```text
bash bin/DPI/checknodes.sh (--localhost | --inventory FICHIER)
                          [--json RAPPORT] [--id IDENTIFIANT] [--oid OBJECTID]
                          [--include-command-line]
bash bin/DPI/checkjava.sh (--localhost | --inventory FICHIER)
                         [--json RAPPORT] [--include-command-line]
bash bin/DPI/checknodes.sh --help
bash bin/DPI/checkjava.sh --help
```

Les éléments entre crochets sont facultatifs. Choisir exactement un mode parmi
`--localhost` et `--inventory`. Les exemples s'exécutent depuis la racine du dépôt.

## DESCRIPTION

**checknodes.sh** produit un document `nodes.json` : identité des machines,
système, Java, CPU, mémoire, interfaces réseau, disques et paquets installés.
La collecte des paquets est intégrée, avec repli automatique de RPM vers dpkg.

**checkjava.sh** relève les processus Java visibles dans `/proc`, avec leurs
identifiants, propriétaires, états, mémoire et threads. Il ne nécessite ni JDK,
ni `jps`, ni `jcmd` et ne recense pas les versions Java installées.

Les scripts sont autonomes, en lecture seule et sans import d'autre script.
Aucun paquet n'est installé ; aucune mise à jour ni élévation de droits n'est
lancée automatiquement. Chaque script doit être exécuté explicitement ; les
contrôles plateforme et flux ne lancent pas les scripts de ce répertoire.

## OPTIONS

| Option | Commande | Effet |
| --- | --- | --- |
| `--localhost` | Les deux | Collecter la machine locale avec le compte courant. |
| `--inventory FICHIER` | Les deux | Lire les cibles et paramètres SSH dans le CSV. |
| `--json RAPPORT` | Les deux | Choisir le fichier de sortie ; refuser un fichier existant. |
| `--include-command-line` | Les deux | Exporter les arguments Java complets. Désactivé par défaut. |
| `--id IDENTIFIANT` | checknodes | Fixer l'identifiant de document `id` ; valeur non vide. |
| `--oid OBJECTID` | checknodes | Fixer `_id.$oid` ; exactement 24 caractères hexadécimaux. |
| `-h`, `--help` | Les deux | Afficher l'aide et quitter. |

Sans identifiants explicites, checknodes génère un nouvel `id` aléatoire de
40 caractères hexadécimaux et un nouvel `_id.$oid` de 24 caractères. Ils identifient
le document, pas durablement la plateforme. Aucune connexion à une base de données
n'est effectuée ; l'import et la mise à jour d'un document relèvent de l'application.

## PRÉREQUIS

| Commande | Outils et accès |
| --- | --- |
| checknodes | Bash, `hostname`, `uname`, `df`, `ps` de procps-ng, `timeout` de coreutils, `/proc`, `/sys`. RPM ou dpkg-query pour les paquets. |
| checkjava | Bash et `/proc`. `readlink` et `getent`, s'ils sont présents, complètent le chemin d'exécutable et le nom d'utilisateur. |
| Collecte distante | Client OpenSSH sur le poste de contrôle ; Bash et serveur SSH accessibles sur la cible. |

Java est facultatif pour checknodes. S'il est présent dans PATH, `java -version`
est exécuté sous un délai de 5 secondes, puis arrêté de force une seconde plus
tard si nécessaire. La résolution FQDN est également bornée quand `timeout` est disponible.

## INVENTAIRE ET SSH

```csv
host;user;port
localhost;;
serveur01;audit;22
serveur02;audit;2222
```

Utiliser le séparateur **`;`** et trois colonnes. L'en-tête est facultatif.
`host` est obligatoire ; utilisateur vide : compte SSH par défaut ; port vide : 22.
Les ports acceptés vont de 1 à 65535. Remplacer les noms d'exemple par les vraies cibles.

Les guillemets doubles, CRLF et BOM UTF-8 sont acceptés. Les guillemets internes
se doublent. Les lignes vides et commentaires commençant par `#` sont ignorés.
Les champs sur plusieurs lignes ne sont pas acceptés. Le fichier est validé
avant la collecte.

`localhost`, `127.0.0.1` et `::1` sont interrogés sans SSH ; utilisateur et port
sont ignorés pour ces entrées. Les autres cibles utilisent une authentification
SSH non interactive et une vérification stricte des clés d'hôte. Préparer une
clé ou un agent et `known_hosts` après vérification des empreintes.

Les cibles sont traitées séquentiellement ; une erreur de connexion n'empêche
pas de traiter les suivantes. Détails dans le [manuel principal](../../README.md#authentification-ssh).

## SORTIE

| Commande | Rapport par défaut | Tableau principal |
| --- | --- | --- |
| checknodes | `nodes.json` | `nodes` |
| checkjava | `rapport-java.json` | `java_inventory` |

La console fournit les cibles, compteurs et diagnostics. Les paquets ne sont jamais
listés en console. Les détails de collecte utilisent aussi stderr en cas de
réussite : consulter le code de retour pour déterminer l'issue.

### Document nodes

L'enveloppe contient `_id`, `id`, `nodes`, `appModules`, `appServers`, `datasources`,
`fluxes`, `info`, `jobs`, `licences`, `metadatas`, `readme`, `referentiels`,
`tablespaces`. Les collections et objets applicatifs restent vides : ces données
ne sont pas déduites du système.

| Champ du nœud | Type et contenu |
| --- | --- |
| `lastUpdate` | Entier : horodatage Unix de début de collecte. |
| `hostname`, `domain`, `fqdn` | Chaînes : identité locale et nom résolu. |
| `ip` | Chaîne : première adresse de `hostname -I`, pas nécessairement celle de SSH ou de la route par défaut. |
| `system.nameOS` | Chaîne : noyau et architecture. |
| `system.versionRedHat` | Chaîne : `/etc/redhat-release`, sinon nom de l'OS. |
| `system.versionJDK` | Chaîne : version Java dans PATH, pas la version de chaque JVM active. Vide si Java est absent. |
| `system.upTime` | Chaîne décimale : secondes depuis le démarrage. |
| `system.load` | Chaîne : charges à 1, 5 et 15 minutes. |
| `processes` | Tableau de chaînes : pourcentage mémoire, PID, utilisateur et commande des processus nommés `java` ou `java.bin`. |
| `cpu.model`, `cpu.nbProc` | Chaînes : modèle et nombre de CPU logiques en ligne. |
| `cpu.frqProc`, `cpu.bogomips` | Chaînes : MHz et BogoMIPS du premier CPU fournissant ces valeurs. |
| `memory` | Nombres en kio : `memTotal`, `memFree`, `memUsed`, `swapTotal`, `swapFree`, `swapUsed`. |
| `network` | Tableau : `nom`, `tx`, `rx`. TX/RX sont des compteurs d'octets cumulés sous forme de chaînes, pas des débits. |
| `disks` | Tableau : `name`, `total`, `used`, `available`, `percentUsed`, `mount`. Capacités numériques en kio ; pourcentage sous forme de chaîne avec `%`. |
| `rpms` | Tableau des paquets, au format commun décrit ci-dessous. |

`memFree` désigne la mémoire réellement libre ; `memUsed` est estimé par
`MemTotal - MemAvailable`. `swapUsed = SwapTotal - SwapFree`.
Une mesure mémoire inconnue vaut `null` ; une chaîne indisponible reste vide.
Les objets de remplissage `{}` ne sont pas ajoutés à `nodes`.

### Paquets RPM et APT

Chaque entrée de `nodes[].rpms` contient exactement six champs :

```json
{"name":"exemple","version":"2:1.0","release":"1ubuntu1","arch":"amd64","size":12288,"group":"utils"}
```

| Champ | Signification |
| --- | --- |
| `name` | Nom du paquet. |
| `version` | Version ; un epoch non nul est conservé au début, suivi de `:`. |
| `release` | Release RPM ou révision Debian ; vide pour une version Debian native. |
| `arch` | Architecture. |
| `size` | Taille installée, entier en octets. |
| `group` | Groupe RPM ou section Debian ; chaîne vide si inconnu. |

RPM est interrogé en premier. S'il est absent, échoue ou renvoie une liste vide
ou invalide, le script interroge automatiquement `dpkg-query`. Seuls les paquets
Debian à l'état `installed` sont retenus. Aucun paramètre de repli n'est nécessaire.

La taille RPM vient de `%{SIZE}` et le groupe de `%{GROUP}`. Pour Debian,
`Installed-Size` est multiplié par 1 024 et le groupe vient de `Section`.
La version Debian est séparée au dernier tiret, sans perdre son epoch.
Les tailles d'exemple ne constituent pas des exigences de livraison.

Les versions multiples, notamment les noyaux, et architectures multiples sont
conservées. Les inventaires RPM et dpkg partiels ne sont jamais mélangés.
Aucune date d'installation n'est collectée. Les logiciels hors des bases RPM/dpkg
et les logiciels internes aux conteneurs ne sont pas recensés par cette collecte.

### Inventaire Java

Chaque entrée de `java_inventory` contient `target`, `exit_code` et `data`.
`data` vaut `null` si l'exécution distante n'a pas pu être réalisée.

Les données contiennent `hostname`, `collected_at_utc`, `scope`, `process_count`,
`processes`, `unreadable_count`, `vanished_count`, `error` et `exit_code`.
Chaque processus expose `pid`, `ppid`, `uid`, `user`, `name`, `state`, `rss_kib`,
`threads`, `executable`, `arguments`.

Par défaut, `arguments` vaut `null`. Avec `--include-command-line`, ce champ est
un tableau qui préserve chaque argument. Les chemins non accessibles restent
vides et une mémoire indisponible vaut `null`.

## CODES DE RETOUR

| Code | Signification |
| --- | --- |
| `0` | Collecte réalisée ; pour checkjava, aucun Java visible est aussi un résultat valide. |
| `2` | Erreur d'utilisation, d'accès ou de collecte ; résultat partiel ou impossible. |

**checknodes :** les nœuds partiellement collectés restent dans le rapport.
Les cibles inaccessibles sont omises et signalées en console. Si RPM et dpkg
échouent, `rpms` reste vide, les mesures système sont conservées et le code vaut 2.
Le document ne contient ni statut d'erreur par nœud ni code global : conserver
les diagnostics console et le code retour en plus du JSON.

**checkjava :** les résultats accessibles sont conservés en cas de collecte
partielle. Les processus disparus pendant le relevé sont comptés séparément.
Les codes SSH sous-jacents, notamment 255, sont conservés dans les entrées de cible.

## EXEMPLES

Collecter une machine ou une plateforme :

```bash
bash bin/DPI/checknodes.sh --localhost --json nodes-local.json
bash bin/DPI/checknodes.sh --inventory examples/serveurs.csv --json nodes-parc.json
```

Fixer les identifiants d'un document à importer :

```bash
bash bin/DPI/checknodes.sh --localhost --id mon-document \
  --oid 0123456789abcdef01234567 --json nodes-import.json
```

Relever les JVM actives :

```bash
bash bin/DPI/checkjava.sh --inventory examples/serveurs.csv --json java-parc.json
```

Ajouter explicitement les arguments Java :

```bash
bash bin/DPI/checknodes.sh --localhost --include-command-line --json nodes-detail.json
bash bin/DPI/checkjava.sh --localhost --include-command-line --json java-detail.json
```

Choisir un nouveau chemin JSON à chaque exécution pour ne pas écraser un rapport.

## VISUALISATION

Ouvrir [visualizer/nodes.html](../../visualizer/nodes.html), puis sélectionner le
JSON de checknodes. Ce seul HTML suffit, sans import, serveur, installation ni
connexion Internet. Les fichiers restent dans la mémoire de la page et ne sont
pas transmis ; fermer ou actualiser la page efface le rapport. Limite : 25 Mio.
L'ouverture directe peut dépendre de la politique du navigateur d'entreprise.

| Vue | Présentation |
| --- | --- |
| Synthèse des serveurs | Un bloc par serveur : OS, uptime au relevé, FQDN/IP, charge, barres RAM/swap et jauges filesystem. |
| Packages | Matrice : une ligne par paquet, une colonne par serveur, versions et architectures multiples conservées. |
| Détail serveur | Système, mémoire, disques, processus, réseau et CPU ; accès par le nom, le bouton de synthèse ou l'en-tête d'une colonne packages. |

Le retour du détail conserve les filtres. Les recherches des vues serveurs et
packages sont mémorisées séparément ; le filtre serveur est partagé.
L'impression PDF porte sur la vue affichée. Les matrices affichent 100 lignes
par défaut, avec un bouton pour tout afficher avant impression.

La recherche, l'architecture et les différences filtrent les listes de paquets.
Taille et groupe sont disponibles au survol d'une version. Les anciens rapports
avec `architecture` restent lisibles ; leurs tailles manquantes ne sont pas inventées.
« Non listé » signifie absent d'une liste fournie, pas absence certifiée sur l'hôte.
Une liste vide ou manquante reste inconnue. Le visualiseur ne reconstitue pas
les erreurs ni les cibles omises et ne peut pas certifier une collecte complète.

Les jauges d'occupation sont bleues sous 80 %, orange à partir de 80 % et rouges
à partir de 90 %. Ce sont des repères visuels, pas des attendus de conformité.
Le pourcentage mémoire utilise les capacités mesurées ; un swap nul est signalé.
Les filesystems utilisent `percentUsed`, sinon `used / total`. Les cercles CPU
montrent des valeurs, pas une utilisation. L'uptime est celui du relevé, pas de
l'instant de lecture. Les objets `{}` du modèle sont ignorés.

Les données applicatives sont affichées si `node.appServers` existe, ou si
`appServers` à la racine référence l'hôte via `hostname`, `nodeHostname` ou `node`.
Les colonnes utilisent `env`/`environment`, `plateforme`/`platform`, `serveur`/`name`,
`xmx`/`XMX`, `port`. Aucune application ni valeur XMX/port n'est inventée.

Le format `java_inventory` n'a pas de vue HTML dédiée dans ce dépôt.

## DIAGNOSTICS ET LIMITES

Les processus sont ceux visibles par le compte de collecte dans son espace de PID.
Les permissions, `hidepid` et les conteneurs peuvent masquer des processus ; une
liste vide ne prouve pas l'absence de JVM sur l'hôte entier.

checkjava retient un nom `java` ou `java.bin`, ou un exécutable dont le chemin se
termine ainsi. Les JVM embarquées dans un autre exécutable et les binaires renommés
peuvent ne pas être détectés. checknodes utilise les noms reconnus par `ps -C`.

`--include-command-line` exporte les arguments tels quels : ils peuvent contenir
des mots de passe ou jetons, visibles dans les rapports, la console Java ou le
visualiseur. Les variables d'environnement des processus ne sont pas lues.

Les paquets nécessitent un accès en lecture à la base locale RPM ou dpkg. Un
échec de RPM n'est pas silencieux : le repli est annoncé en console. Si les deux
bases sont inutilisables, une liste vide ne doit pas être interprétée comme un
inventaire réussi. `df` peut attendre sur un montage réseau défaillant.

Pour les erreurs SSH, DNS ou de fichier de sortie, consulter les
[diagnostics du manuel principal](../../README.md#diagnostics-et-limites).

## FICHIERS

| Chemin | Rôle |
| --- | --- |
| `bin/DPI/checknodes.sh` | Collecte nodes et paquets intégrés. |
| `bin/DPI/checkjava.sh` | Inventaire des processus Java. |
| `examples/serveurs.csv` | Exemple d'inventaire partagé par les scripts. |
| `visualizer/nodes.html` | Lecteur nodes autonome, serveurs et packages. |
| `/proc`, `/sys` | Mesures et identité des processus, CPU, mémoire et interfaces. |
| `/etc/redhat-release`, `/etc/os-release` | Identification de la distribution. |

Les scripts et le HTML sont livrables séparément ; aucune bibliothèque locale
à importer n'est nécessaire. Les futurs scripts DPI doivent être lancés explicitement.

## VOIR AUSSI

[Manuel principal](../../README.md), bash(1), ssh(1), proc(5), ps(1), rpm(8), dpkg-query(1), java(1).

## LICENCE

Voir [LICENSE](../../LICENSE).
