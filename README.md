# CheckPlateforme

Vérification en ligne de commande d'une plateforme RHEL, en lecture seule,
sans interface graphique, agent distant ni installation automatique de paquets.

```bash
bash bin/checkplateforme.sh --localhost
bash bin/checkplateforme.sh --inventory examples/serveurs.txt
```

Prérequis : Bash, uname, df et systemd sur les serveurs, normalement disponibles
sur RHEL minimal. Le mode distant nécessite en plus un client OpenSSH sur le
poste de contrôle et un serveur SSH accessible sur chaque cible. Aucun sudo requis.

Configurer les clés SSH ou l'agent SSH et enregistrer les clés d'hôte après
vérification des empreintes. Les clés inconnues ou modifiées sont refusées.
Aucun mot de passe interactif n'est demandé. La configuration SSH existante est utilisée.

## Inventaire

Une cible par ligne : `hôte [utilisateur [port]]`, séparés par des espaces ou
tabulations. Utilisateur facultatif, port 22 par défaut. Pour préciser un port,
fournir aussi un utilisateur. Lignes vides et commentaires # acceptés.
Aucun secret ni commande shell dans l'inventaire.

```text
serveur01
192.0.2.10 audit 22
serveur03 audit 2222
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
