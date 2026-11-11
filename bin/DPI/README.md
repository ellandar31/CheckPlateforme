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
