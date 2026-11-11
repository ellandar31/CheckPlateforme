# CheckPlateforme

Vérification en ligne de commande d'une plateforme RHEL, en lecture seule,
sans interface graphique, agent distant ni installation automatique de paquets.

```bash
bash bin/checkplateforme.sh --localhost
bash bin/checkplateforme.sh --inventory examples/serveurs.csv
```

Prérequis : Bash, uname, df et systemd sur les serveurs, normalement disponibles
sur RHEL minimal. Le mode distant nécessite en plus un client OpenSSH sur le
poste de contrôle et un serveur SSH accessible sur chaque cible. Aucun sudo requis.

Configurer les clés SSH ou l'agent SSH et enregistrer les clés d'hôte après
vérification des empreintes. Les clés inconnues ou modifiées sont refusées.
Aucun mot de passe interactif n'est demandé. La configuration SSH existante est utilisée.

## Inventaire

Fichier CSV séparé par des **points-virgules (`;`)**, avec trois colonnes `host;user;port`.
L'en-tête est facultatif. Une cible par ligne, avec trois champs obligatoires :
`user` et `port` peuvent être vides (compte SSH par défaut et port 22).
Les champs peuvent être entre guillemets doubles ; les fins de ligne Windows
(CRLF) et le BOM UTF-8 sont acceptés. Pas de champs sur plusieurs lignes.
Les lignes vides et les lignes commençant par `#` sont ignorées.
Les anciens fichiers séparés par des virgules, espaces ou tabulations doivent être convertis.
Aucun secret ni commande shell dans l'inventaire.

```csv
host;user;port
localhost;;
serveur01;;
192.0.2.10;audit;22
serveur03;audit;2222
```

Le fichier entier est validé avant connexion. Les cibles sont traitées
séquentiellement ; une erreur n'empêche pas le contrôle des suivantes.

## Contrôles initiaux

- Distribution RHEL attendue et identification de la version.
- Noyau et architecture.
- CPU : modèle et nombre de processeurs logiques en ligne.
- RAM : totale, disponible et utilisée estimée (totale moins disponible), en kio.
- Swap : totale, libre et utilisée, en kio ; absence de swap signalée.
- Espace des systèmes de fichiers.
- État systemd et unités en échec.

Codes de sortie : **0** conforme aux contrôles exécutés, **1** écart,
**2** erreur de collecte ou d'utilisation. Une erreur est prioritaire sur un écart.
Un contrôle indisponible est signalé comme une erreur.

Cette première version constitue un état technique de base. Les versions
acceptées, seuils CPU/mémoire/disque, partitions, services et paramètres réseau
attendus restent à définir selon le cahier de livraison. Les valeurs mémoire et
disque sont informatives. CPU, RAM et swap sont lus directement dans `/proc`,
sans paquet supplémentaire. df peut attendre sur un montage réseau défaillant.

## Validation

```bash
bash -n bin/checkplateforme.sh
bash -n bin/checkflux.sh
bash -n bin/lib/common.sh
python3 tests/test_json.py
```

Valider les contrôles complets sur une VM RHEL démarrée avec systemd.
Un conteneur Linux ne remplace pas ce test.

## Rapport JSON

Chaque exécution de `checkplateforme.sh` produit `rapport.json` dans le répertoire courant, en plus de
l'affichage console. Choisir un autre fichier avec `--json` :

```bash
bash bin/checkplateforme.sh --localhost --json controle-local.json
bash bin/checkplateforme.sh --inventory examples/serveurs.csv --json controle-parc.json
```

Un fichier existant est refusé pour éviter tout écrasement ; utiliser un nouveau
nom à chaque exécution. Aucun paquet supplémentaire (`jq`, Python…) n'est requis.
Les détails console de la collecte passent sur stderr ; ils restent visibles.

Le rapport contient `servers` (une entrée par cible) et un `exit_code` global.
Chaque entrée contient `target`, `exit_code` et `data` : distribution, noyau,
CPU, RAM et swap en kio, tableau `filesystems` et état systemd.
Chaque entrée de `filesystems` contient `device`, `mountpoint`, `size_kib`,
`used_kib`, `available_kib` et `use_percent` (nombre de 0 à 100 ou plus selon df).
Le tableau remplace l'ancien champ `filesystems_text`. L'affichage console
reste identique. Les tailles sont exprimées en blocs de 1 kio (1 024 octets).
Les valeurs mémoire inconnues valent `null`. En cas d'échec SSH, `data` vaut
`null` et le code SSH est conservé (généralement 255). Les diagnostics restent
dans la console. Les codes de sortie du programme restent inchangés.

## Cibles locales et erreurs SSH

Dans l'inventaire, `localhost`, `127.0.0.1` et `::1` exécutent les contrôles
localement, sans SSH, avec le compte courant. Les champs utilisateur et port
sont alors ignorés. Les autres cibles utilisent SSH.

Les noms `rhel01.example.local` et `rhel02.example.local` du fichier exemple
sont à remplacer par les noms DNS résolvables ou adresses IP de vos serveurs.
Une erreur « Could not resolve hostname » indique un problème de nom ou de DNS.
Pour une cible distante dont la clé SSH est inconnue, vérifier son empreinte
auprès de l'administrateur, puis enregistrer la clé avec une première connexion
SSH interactive. Le contrôle strict des clés reste activé.

## Contrôle des flux réseau

Le script `bin/checkflux.sh` est indépendant de `checkplateforme.sh` : il ne
collecte ni CPU, ni mémoire, ni filesystems, ni état systemd.
La matrice `--flows` est obligatoire pour ce script. Son exécution reste
facultative : ne lancer que `checkplateforme.sh` pour contrôler la plateforme.
L’ancienne option `checkplateforme.sh --flows` est retirée.

Exécuter les flux séparément :

```bash
bash bin/checkflux.sh --localhost --flows flux-local.csv --json local-flux.json
bash bin/checkflux.sh --inventory examples/serveurs.csv --flows examples/flux.csv --json parc-flux.json
```

La matrice CSV utilise le séparateur `;` et comporte cinq colonnes, avec en-tête facultatif :

```csv
source;destination;port;protocole;description
localhost;192.0.2.10;22;tcp;SSH et SFTP
serveur01;192.0.2.20;1521;tcp;Oracle SQLPlus
serveur01;192.0.2.53;53;udp;DNS
```

Remplacer les noms et adresses d'exemple. Les sources distantes doivent être
présentes dans l'inventaire : leur utilisateur et port SSH y sont récupérés.
`--localhost` n'accepte que des sources locales (`localhost`, `127.0.0.1`, `::1`).
Les destinations n'ont pas besoin de figurer dans l'inventaire.
La matrice entière et les sources sont validées avant tout contrôle.
Les tests sont séquentiels, exécutés depuis chaque source et non depuis le poste
qui pilote les connexions SSH. Aucun secret applicatif n'est nécessaire.

Pour TCP, Bash ouvre une connexion sans envoyer de données applicatives.
`timeout` (GNU coreutils, normalement présent sur RHEL minimal) limite chaque
test, résolution DNS comprise, à 5 secondes (arrêt forcé après 1 seconde de plus).
`getent`, s'il est disponible sur la source, permet d'identifier les erreurs de
résolution. Aucun paquet n'est installé automatiquement.

Les résultats console et JSON distinguent `accessible`, `refused`, `timeout`,
`dns_error`, `connection_error`, `source_error` et `indeterminate`.
Le tableau `flows` contient une entrée par ligne de matrice : source, destination,
port, protocole, description et résultat (statut, détail, code de sortie).
Un refus ou un délai dépassé ne prouve pas un blocage par le pare-feu : le service
peut ne pas écouter, ou la destination/le routage peut être indisponible.
Ces tests ne valident pas l'authentification SSH/SFTP ni une connexion SQLPlus.

**UDP :** les lignes sont acceptées mais signalées `indeterminate`, sans émission
de paquet. Sans requête et réponse propres au service, il est impossible de
confirmer l'ouverture du flux. Aucun succès UDP n'est annoncé par défaut.

Un échec de connectivité contribue au code global **1** ; un test indéterminé,
un outil manquant ou une erreur d'exécution contribue au code **2**.
Le rapport par défaut est `rapport-flux.json`, avec uniquement `flows` et
`exit_code`. Les codes retour de la plateforme et des flux sont indépendants :
un système dégradé n’affecte pas le résultat des tests réseau.
Le code 2 reste prioritaire sur 1 dans chaque rapport.

## Attendus par serveur (optionnels)

L'option `--expectations` compare les mesures aux exigences de livraison, sans
installation supplémentaire. Elle appartient uniquement au script plateforme :

```bash
bash bin/checkplateforme.sh --localhost --expectations examples/attentes.csv --json conformite.json
bash bin/checkplateforme.sh --inventory exemples-parc.csv --expectations attentes-parc.csv --json parc.json
```

CSV avec séparateur `;`, de six colonnes, avec en-tête facultatif :

```csv
host;resource;mountpoint;operator;value;unit
localhost;cpu;;ge;4;count
localhost;ram;;ge;8192;MiB
localhost;swap;;eq;0;MiB
localhost;filesystem_size;/;ge;20480;MiB
```

- `host` : nom exact dans l'inventaire ; pour `--localhost`, écrire `localhost`.
- `cpu` : nombre de processeurs logiques en ligne (`count`).
- `ram` et `swap` : capacité totale, en `MiB` (1 MiB = 1 024 kio).
- `filesystem_size` : seule la capacité totale du filesystem monté au chemin indiqué est comparée (MiB).
  L’espace disponible et le pourcentage utilisé restent informatifs en console et dans le JSON.
- `ge` : supérieur ou égal ; `eq` : égal ; `le` : inférieur ou égal.

Le point de montage est obligatoire pour les ressources filesystem et doit être
vide pour CPU/RAM/swap. La valeur est un entier positif ou nul (12 chiffres maximum).
Les exigences filesystem portent sur un **point de montage exact** : `/var`
absent de la liste des montages est un écart, même si le dossier existe sur `/`.
Plusieurs règles peuvent viser un serveur ; les autres serveurs sont collectés
sans contrôle d'attendus. Les règles strictement dupliquées sont refusées.
Les hôtes non sélectionnés, unités et règles invalides sont rejetés avant collecte.

Chaque résultat est affiché en console et dans `servers[].data.expectations` :
ressource, point de montage, opérateur, attendu, mesuré, unité et statut
`pass`, `fail` ou `error`. Les valeurs MiB du CSV sont converties en `KiB` dans
le JSON pour une comparaison précise avec les mesures de `/proc` et `df`.
Une mesure inconnue vaut `null`. Un écart contribue au code **1**, une erreur
au code **2**, qui reste prioritaire. Sans l'option, `expectations` est vide.

La RAM mesurée est la mémoire utilisable par Linux (`MemTotal`), qui peut être
légèrement inférieure à la RAM physique allouée. Prévoir cette différence dans
le seuil de livraison, plutôt qu'une égalité stricte avec la capacité nominale.

## Organisation des scripts

```text
bin/
├── checkplateforme.sh   # Collecte et comparaison aux attendus
├── checkflux.sh         # Tests des flux depuis une matrice
├── lib/common.sh        # Fonctions communes JSON, CSV et inventaire
└── DPI/
    └── README.md        # Emplacement des futurs scripts spécifiques
```

Conserver `bin/lib/common.sh` avec les deux scripts lors de leur copie sur un
poste de contrôle. Cette bibliothèque ne réalise aucun contrôle à son chargement
et n'a pas besoin d'être copiée sur les sources SSH : seules les fonctions
nécessaires sont transmises à chaque exécution distante.

Le répertoire `bin/DPI` accueille vos scripts spécifiques de collecte d'informations
sur la plateforme. Son contenu n'est exécuté automatiquement par aucun des deux
scripts ; lancer explicitement les scripts que vous y ajouterez.
