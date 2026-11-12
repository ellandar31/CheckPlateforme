# CHECKPLATEFORME(1)

## NOM

checkplateforme, checkflux — contrôler une livraison Linux et ses flux réseau.

## SYNOPSIS

```text
bash bin/checkplateforme.sh (--localhost | --inventory FICHIER)
                           [--expectations FICHIER] [--json RAPPORT]
bash bin/checkflux.sh (--localhost | --inventory FICHIER)
                     --flows MATRICE [--json RAPPORT]
bash bin/checkplateforme.sh --help
bash bin/checkflux.sh --help
```

Les éléments entre crochets sont facultatifs. `--localhost` et `--inventory`
sont mutuellement exclusifs. Les chemins des exemples partent de la racine du dépôt.

## DESCRIPTION

**checkplateforme.sh** relève la distribution, le noyau, l'architecture, les CPU
logiques, la RAM, le swap, les filesystems et l'état systemd. La distribution
attendue est RHEL. Les valeurs CPU, mémoire et disque restent informatives tant
qu'aucun fichier d'attendus n'est fourni.

**checkflux.sh** teste les connexions définies dans une matrice depuis chaque
serveur source. Il ne lance aucun contrôle de plateforme. Les rapports et codes
de retour des deux commandes sont indépendants.

Chaque script est autonome, en lecture seule et utilisable sans interface
graphique. Aucun paquet n'est installé et aucun `sudo` n'est exécuté automatiquement.
Les cibles d'un inventaire sont traitées séquentiellement ; une erreur sur un
serveur n'empêche pas de traiter les suivants.

Les collectes DPI, dont l'export complet `nodes.json` avec ses paquets, sont
documentées dans le [manuel DPI](bin/DPI/README.md).

## OPTIONS

| Option | Commande | Effet |
| --- | --- | --- |
| `--localhost` | Les deux | Exécuter depuis la machine locale. Pour les flux, n'accepter que des sources locales. |
| `--inventory FICHIER` | Les deux | Lire les cibles et paramètres SSH dans un CSV. |
| `--json RAPPORT` | Les deux | Écrire le JSON dans ce fichier. Un fichier existant est refusé. |
| `--expectations FICHIER` | checkplateforme | Comparer les mesures aux exigences de livraison. |
| `--flows MATRICE` | checkflux | Lire les flux à tester. Obligatoire pour cette commande. |
| `-h`, `--help` | Les deux | Afficher l'aide et quitter. |

## PRÉREQUIS

Pour la plateforme : Bash, `uname`, `df`, `/proc` et systemd démarré. Un conteneur
sans systemd ne valide pas ce contrôle. Ces outils sont normalement disponibles
sur une installation minimale de RHEL.

Pour les flux TCP : Bash avec `/dev/tcp` et `timeout` de GNU coreutils sur chaque
source. `getent`, s'il est disponible, aide à identifier les erreurs de résolution.
Chaque test TCP, résolution comprise, est limité à 5 secondes, puis arrêté de
force une seconde plus tard si nécessaire.

Pour les sources ou cibles distantes : client OpenSSH sur le poste de contrôle,
Bash et serveur SSH accessibles sur les machines interrogées.

## AUTHENTIFICATION SSH

L'accès distant utilise `BatchMode=yes` et `StrictHostKeyChecking=yes`. Préparer
une clé SSH ou un agent et enregistrer les clés d'hôte après vérification de leurs
empreintes. Les demandes de mot de passe interactives et les clés inconnues ou
modifiées font échouer la connexion. La configuration SSH existante est conservée.

Dans l'inventaire, `localhost`, `127.0.0.1` et `::1` déclenchent une exécution locale
sans SSH. Le compte courant est utilisé ; utilisateur et port du CSV sont ignorés.
Pour tester réellement SSH vers sa propre machine, utiliser son adresse réseau.

## FORMATS DES FICHIERS

### Règles CSV

Tous les CSV utilisent **`;`**. Les en-têtes indiqués sont facultatifs. Respecter
le nombre de colonnes, même lorsqu'un champ est vide.

Les champs peuvent être entre guillemets doubles ; un guillemet interne se double.
Les lignes vides et celles commençant par `#` sont ignorées. Les fins de ligne
Windows (CRLF) et le BOM UTF-8 sont acceptés. Les champs sur plusieurs lignes ne
sont pas pris en charge. Aucun secret ni commande shell ne doit figurer dans ces CSV.

Les fichiers sont validés avant les contrôles. Remplacer les hôtes d'exemple par
des noms résolvables ou des adresses IP réelles.

### Inventaire des serveurs

```csv
host;user;port
localhost;;
serveur01;audit;22
192.0.2.10;audit;2222
```

`host` est obligatoire. `user` vide utilise le compte SSH par défaut ; `port` vide
vaut 22. Les ports autorisés vont de 1 à 65535.

### Attendus de plateforme

```csv
host;resource;mountpoint;operator;value;unit
localhost;cpu;;ge;4;count
localhost;ram;;ge;8192;MiB
localhost;swap;;eq;0;MiB
localhost;filesystem_size;/;ge;20480;MiB
```

| Colonne | Valeur attendue |
| --- | --- |
| `host` | Nom exact sélectionné dans l'inventaire ; `localhost` en mode local. |
| `resource` | `cpu`, `ram`, `swap` ou `filesystem_size`. |
| `mountpoint` | Point de montage absolu pour un filesystem ; vide pour CPU/RAM/swap. |
| `operator` | `ge` : minimum ; `eq` : égalité ; `le` : maximum. |
| `value` | Entier positif ou nul, 12 chiffres maximum. |
| `unit` | `count` pour CPU ; `MiB` pour RAM, swap et filesystem. |

La comparaison utilise les CPU logiques en ligne, la RAM et le swap totaux,
et **uniquement la taille totale** des filesystems. Le montage doit correspondre
exactement : un dossier `/var` présent sur `/` ne remplace pas un montage `/var`.
Un montage attendu absent est un écart. Une mesure indisponible est une erreur.
Les règles dupliquées pour un même hôte, ressource, montage et opérateur sont refusées.
Un serveur sans règle reste collecté sans comparaison aux attendus.

La RAM correspond à `MemTotal`, donc à la mémoire utilisable par Linux ; elle peut
être inférieure à la capacité physique nominale. Prévoir cette différence dans le seuil.

### Matrice des flux

```csv
source;destination;port;protocole;description
localhost;192.0.2.10;22;tcp;SSH et SFTP
serveur01;192.0.2.20;1521;tcp;Oracle SQLPlus
serveur01;192.0.2.53;53;udp;DNS
```

Chaque source distante doit figurer dans l'inventaire pour fournir son utilisateur
et son port SSH. La destination n'a pas besoin d'y figurer. Les seuls protocoles
acceptés sont `tcp` et `udp`. Le test s'exécute sur la source indiquée.

TCP ouvre une connexion sans envoyer de données applicatives. SSH, SFTP et Oracle
sont ici des descriptions de services : ni authentification ni requête SQL n'est testée.
UDP est accepté dans la matrice mais retourne `indeterminate`, sans émission de
paquet : une réponse propre au service serait nécessaire pour conclure.

## SORTIE

Les informations de collecte sont affichées dans la console et enregistrées dans
un JSON. Les détails de collecte peuvent utiliser stderr même en cas de réussite.
Le code de retour, et non la présence de texte sur stderr, indique le résultat.

| Commande | Rapport par défaut | Champs racine |
| --- | --- | --- |
| checkplateforme | `rapport.json` | `servers`, `exit_code` |
| checkflux | `rapport-flux.json` | `flows`, `exit_code` |

Dans `servers[]`, `target` identifie la cible, `exit_code` son résultat et `data`
les mesures. `data` peut valoir `null` en cas d'échec distant.

Les mesures de plateforme comprennent `cpu`, `ram_kib`, `swap_kib`, `filesystems`,
`systemd` et `expectations`. Chaque filesystem expose `device`, `mountpoint`,
`size_kib`, `used_kib`, `available_kib`, `use_percent`.
Les attendus indiquent règle, attendu, mesuré, unité et statut `pass`, `fail` ou
`error`. Les MiB du CSV sont convertis en KiB pour la comparaison JSON ; une
mesure inconnue vaut `null`. Sans fichier d'attendus, `expectations` est vide.

Chaque entrée de `flows` contient source, destination, port, protocole, description
et `result` : `status`, `detail`, `exit_code`. Les statuts possibles sont
`accessible`, `refused`, `timeout`, `dns_error`, `connection_error`, `source_error`
et `indeterminate`.

**Unités :** 1 kio = 1 024 octets ; 1 Mio = 1 024 kio. Les noms de champs `kib`/`KiB`
et les unités `MiB` reprennent ces mêmes unités binaires.

## CODES DE RETOUR

| Code | Signification |
| --- | --- |
| `0` | Contrôles exécutés sans écart signalé ; flux TCP accessibles. |
| `1` | Au moins un écart de plateforme ou un échec de connectivité. |
| `2` | Erreur d'utilisation, de collecte ou d'exécution ; test indéterminé. |

Le code 2 est prioritaire sur 1. Les codes SSH sous-jacents, notamment 255, peuvent
être conservés dans les entrées JSON ; le code global du script reste normalisé.
Un résultat 0 sans attendus ne certifie pas une conformité à un cahier de livraison.

## EXEMPLES

Contrôler la machine locale avec des attendus :

```bash
bash bin/checkplateforme.sh --localhost \
  --expectations examples/attentes.csv --json plateforme-local.json
```

Contrôler un parc, puis tester ses flux indépendamment :

```bash
bash bin/checkplateforme.sh --inventory examples/serveurs.csv --json plateforme.json
bash bin/checkflux.sh --inventory examples/serveurs.csv \
  --flows examples/flux.csv --json flux.json
```

Consulter l'aide sans exécuter de contrôle :

```bash
bash bin/checkplateforme.sh --help
bash bin/checkflux.sh --help
```

## VISUALISATION

Ouvrir [visualizer/index.html](visualizer/index.html) dans un navigateur récent,
puis charger le rapport dans la vue **Plateforme** ou **Flux réseau**.
Recherche, filtre des anomalies et impression PDF portent sur les résultats affichés.
Les deux rapports restent indépendants et sont conservés pendant la session de page.

Le HTML est autonome : livrer ce seul fichier avec les JSON. Aucun serveur,
installation, import ou accès Internet n'est requis. Les rapports ne sont pas
transmis et ne sont pas stockés durablement ; recharger la page les efface.
Limite : 25 Mio par fichier. En cas de JSON invalide, le précédent rapport reste affiché.
L'ouverture de fichiers HTML locaux peut dépendre de la politique du navigateur.

Le visualiseur DPI [visualizer/nodes.html](visualizer/nodes.html) est décrit dans
le [manuel DPI](bin/DPI/README.md#visualisation).

## DIAGNOSTICS ET LIMITES

| Diagnostic | Vérification à effectuer |
| --- | --- |
| Clé SSH inconnue ou modifiée | Vérifier l'empreinte du serveur, puis préparer `known_hosts`. |
| Authentification non interactive impossible | Vérifier la clé SSH, l'agent et le compte utilisé. |
| Nom d'hôte non résolu | Corriger le nom ou la configuration DNS ; retirer les noms d'exemple. |
| Rapport déjà existant | Choisir un nouveau chemin de sortie. |
| systemd indisponible | Tester sur une machine Linux démarrée avec systemd. |
| Connexion refusée | Vérifier le service à l'écoute et les éventuels rejets réseau. |
| Délai dépassé | Examiner destination, routage et filtrage. |

Un échec TCP ne prouve pas à lui seul un blocage du pare-feu. Un port doit avoir
un service à l'écoute pour produire une connexion réussie. UDP indéterminé ne
signifie pas flux ouvert. `df` peut attendre sur un montage réseau défaillant.

## FICHIERS

| Chemin | Rôle |
| --- | --- |
| `bin/checkplateforme.sh` | Contrôles et attendus de plateforme. |
| `bin/checkflux.sh` | Contrôles de flux. |
| `bin/DPI/` | Scripts spécifiques, tous exécutés explicitement. |
| `examples/serveurs.csv` | Exemple d'inventaire. |
| `examples/attentes.csv` | Exemple d'attendus. |
| `examples/flux.csv` | Exemple de matrice réseau. |
| `visualizer/index.html` | Lecteur plateforme/flux autonome. |
| `visualizer/nodes.html` | Lecteur nodes avec synthèse, détail et packages. |

Les scripts ne nécessitent aucun autre fichier shell pour être livrés.

## DÉVELOPPEMENT

Les dépendances de test ne sont pas requises sur les serveurs clients.
Depuis la racine du dépôt :

```bash
python3 -m unittest discover -s tests -p 'test_*.py'
```

Les tests navigateur nécessitent Playwright et Chromium. La validation cloud
charge le HTML exact hors connexion, car le navigateur géré y bloque `file://`.
La validation de collecte complète RHEL exige une machine RHEL démarrée avec systemd.

## VOIR AUSSI

[Manuel DPI](bin/DPI/README.md), bash(1), ssh(1), ssh_config(5), df(1), systemctl(1), timeout(1).

## LICENCE

Voir [LICENSE](LICENSE).
