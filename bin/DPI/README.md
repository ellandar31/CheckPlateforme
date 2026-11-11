# Scripts spécifiques DPI

Placer ici les scripts spécifiques de collecte d'informations de la plateforme.
Aucun script de ce répertoire n'est exécuté automatiquement par
`checkplateforme.sh` ou `checkflux.sh` : lancer explicitement le script souhaité.

Utiliser Bash et les commandes déjà présentes sur RHEL minimal, privilégier les
collectes en lecture seule et documenter les éventuels prérequis de chaque script.
Ne pas stocker de mots de passe, clés privées ou rapports contenant des secrets ici.

## Inventaire des paquets installés

`checkpackages.sh` est autonome, en lecture seule, sans installation de paquet
ni import d'un autre script. Il nécessite Bash et `rpm` sur chaque cible RHEL.
Aucun sudo n'est requis pour consulter la base RPM.

```bash
# Machine locale
bash bin/DPI/checkpackages.sh --localhost --json packages-local.json

# Plateforme entière, avec le même inventaire que les autres scripts
bash bin/DPI/checkpackages.sh --inventory examples/serveurs.csv --json packages-parc.json
```

L'inventaire utilise le séparateur `;` :

```csv
host;user;port
localhost;;
serveur01;audit;22
serveur02;audit;2222
```

Les sources locales (`localhost`, `127.0.0.1`, `::1`) sont interrogées directement.
Les autres serveurs utilisent SSH avec authentification non interactive et
vérification stricte des clés d'hôte, comme les autres scripts.
Une cible inaccessible n'empêche pas de traiter les suivantes.

La console affiche les paquets de chaque serveur. Le JSON par défaut est
`rapport-packages.json` ; un rapport existant n'est jamais écrasé.
Le tableau `package_inventory` contient, pour chaque cible, `target`, `exit_code`
et `data` (ou `null` si la collecte distante n'a pas pu être exécutée).
Les données contiennent le nom du serveur, le nombre de paquets, une éventuelle
erreur et le tableau `packages` :

- `name` : nom du paquet ;
- `epoch`, `version`, `release` : version RPM complète ;
- `architecture` : architecture ;
- `installed_at_unix` : date d'installation, en secondes depuis l'époque Unix UTC.

Toutes les occurrences RPM sont conservées, notamment les différents noyaux
installés ou les variantes d'architecture d'un même paquet. L'ordre est celui
de la base RPM. Cette collecte ne recense pas les logiciels installés hors RPM,
les paquets dans les conteneurs ou les environnements Python/npm.
Une liste vide, une réponse invalide ou un échec RPM sont des erreurs ; aucune
liste partielle n'est présentée comme complète.

Codes de retour : **0** toutes les collectes réussies, **2** au moins une erreur.
Les échecs SSH conservent aussi leur code (par exemple 255) dans l'entrée de cible.
Ce rapport DPI est distinct des deux formats plateforme/flux pris en charge par
le visualiseur HTML actuel.

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
