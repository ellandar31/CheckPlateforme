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

Fichier CSV séparé par des **virgules**, avec trois colonnes `host,user,port`.
L'en-tête est facultatif. Une cible par ligne, avec trois champs obligatoires :
`user` et `port` peuvent être vides (compte SSH par défaut et port 22).
Les champs peuvent être entre guillemets doubles ; les fins de ligne Windows
(CRLF) et le BOM UTF-8 sont acceptés. Pas de champs sur plusieurs lignes.
Les lignes vides et les lignes commençant par `#` sont ignorées.
Les anciens fichiers séparés par des espaces ou tabulations doivent être convertis.
Aucun secret ni commande shell dans l'inventaire.

```csv
host,user,port
localhost,,
serveur01,,
192.0.2.10,audit,22
serveur03,audit,2222
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
bash bin/checkplateforme.sh --help
```

Valider les contrôles complets sur une VM RHEL démarrée avec systemd.
Un conteneur Linux ne remplace pas ce test.

## Rapport JSON

Chaque exécution produit `rapport.json` dans le répertoire courant, en plus de
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
