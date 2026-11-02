# DOSSIER.md - XTI302-CYB, contexte C (BioLab)

## 1. Tableau de conformité

| ID | Ce qui a été fait | Test verifier.sh | Référence ANSSI |
|---|---|---|---|
| C1 | `creer_comptes.sh` lit `comptes.csv`, crée groupes puis comptes (idempotent via `id`/`getent`) | `test_C1` | R23 |
| C2 | `/srv/*` créés avec `setfacl` (ACL nominales + ACL par défaut `-d`) | `test_C2_*` | R24 |
| C3 | `admins` : `%admins ALL=(ALL:ALL) ALL` ; `support` : une seule ligne NOPASSWD vers `analyse_logs.sh` | `test_C3_*` | R68-R71 |
| C4 | `passwd -l root` ; `chmod 750` sur les home | `test_C4_*` | R15 |
| S1 | `PasswordAuthentication no` | `test_S1` | R38 |
| S2 | `PermitRootLogin no` | `test_S2` | R37 |
| S3 | `AllowGroups acces_ssh` | `test_S3` | R39 |
| S4 | `MaxAuthTries 4` ; `ClientAliveInterval 300` × `ClientAliveCountMax 3` = 15 min | `test_S4_*` | R40 |
| S5 | fichier dans `sshd_config.d/`, validé par `sshd -t` avant `systemctl reload ssh` | `test_S5` | - |
| J1 | fail2ban, jail `sshd`, mode `aggressive` (nécessaire en SSH clé-seule, voir Choix techniques), 4 échecs / 10 min -> ban 10 min. Testé avec une vraie tentative de clé invalide, bannissement confirmé. | `test_J1_*` | R52 |
| J2 | nftables, `policy drop` en entrée, autorise `lo`, `established,related`, port 22 | `test_J2_*` | R52 |
| J3 | `Storage=persistent` dans `journald.conf.d/` | `test_J3` | R55 |
| J4 | `analyse_logs.sh` lit `journalctl -u ssh.service`, seuil configurable (`SEUIL`, défaut 10) | `test_J4` | - |
| B1 | `sauvegarde.sh` : `rsync -aAX --link-dest=<version précédente>`, purge au-delà de 7 versions | `test_B1_*` | R57 |
| B2 | `sauvegarde.timer` (02h00 quotidien), journalisé dans `/var/log/sauvegarde.log` et le journal systemd | `test_B2` | - |
| B3 | `/mnt/sauvegarde` : `chown root:admins`, `chmod 750` | `test_B3` | - |
| B4 | Voir section 4 (procédure de restauration testée) | `test_B4` | - |
| D1 | `unattended-upgrades` activé, limité à `*-security` | `test_D1` | R64 |
| D2 | seul le port 22 écoute (`ss -tulpn`) | `test_D2` | R27 |
| D3 | aucun fichier modifiable par tous hors `/tmp` ; SUID recensés ci-dessous | `test_D3_*` | R17 |

## 2. Choix techniques

- **Seuil fail2ban** : 4 échecs en 10 minutes, bannissement 10 minutes.
  Choisi pour coller à `MaxAuthTries 4` (S4) : un client qui épuise ses
  tentatives sur une seule connexion ne doit pas forcément être banni
  immédiatement, mais le refaire une fois de plus dans les 10 minutes
  déclenche le ban.
- **`mode = aggressive` pour la jail sshd** (et pas le `normal` par
  défaut) : testé en conditions réelles (4 tentatives de clé invalide
  depuis l'hôte), le mode `normal` de fail2ban ne détectait **aucun**
  échec, car sur une config SSH clé-seule (S1) les tentatives refusées
  ne produisent jamais de ligne `Failed password` mais des fermetures
  pré-authentification (`Connection closed by authenticating user ...
  [preauth]`, `drop connection ... penalty: failed authentication`
  sur OpenSSH récent) que le filtre par défaut classe explicitement
  comme non-échecs en mode `normal`. `aggressive` les compte comme des
  échecs. Sans ce correctif, J1 était actif mais inefficace contre le
  seul type d'attaque possible ici.
- **Seuil d'alerte `analyse_logs.sh`** : 10 échecs pour une même IP,
  réglable via la variable d'environnement `SEUIL`. Choisi pour rester
  au-dessus du nombre normal d'erreurs de frappe d'un utilisateur
  légitime, mais bien en dessous d'une attaque par force brute.
- **7 versions de sauvegarde conservées (B1)** : imposé par le sujet.
  Avec un disque de 2 Go et `--link-dest` (hardlinks sur les fichiers
  inchangés), 7 versions quotidiennes de `/srv` + `/etc` tiennent
  largement.
- **ACL plutôt que des groupes supplémentaires** : le sujet impose des
  droits différents par répertoire pour les mêmes 4 groupes métier ; les
  permissions Unix classiques (rwx propriétaire/groupe/autres) ne
  suffisent pas à distinguer plus de deux niveaux d'accès simultanés
  sur un même répertoire, d'où les ACL (`setfacl`) avec ACL par défaut
  pour les fichiers créés après coup (`-d`).

## 3. Défense

Attaques rendues plus difficiles par cette configuration :

1. **Force brute SSH sur un mot de passe** : impossible, authentification
   par clé uniquement (S1). Même en tentant plusieurs clés invalides,
   fail2ban bannit après 4 échecs répétés (J1, testé réellement : voir
   Choix techniques pour le correctif `mode = aggressive`, sans lequel
   ces tentatives seraient passées inaperçues).
2. **Connexion directe en root** : refusée par SSH (S2) ; de plus le
   compte root est verrouillé localement (C4), donc même avec le mot de
   passe personne ne peut l'utiliser pour se connecter ou faire un `su`.
3. **Compte métier curieux** (ex: un doctorant qui essaie de lire
   `/srv/donnees_brutes`) : bloqué par les ACL (C2), et de toute façon
   ces comptes ne sont pas dans `acces_ssh` donc ne peuvent même pas se
   connecter en SSH pour essayer localement sans accès physique.
4. **Compte `support` compromis** : le sudoers de `support` ne permet
   d'exécuter qu'un seul script, appartenant à root et non modifiable
   par `support` (C3) ; impossible d'en faire un détournement GTFOBins
   classique (pas de `sudo -l` ouvert sur un shell, un éditeur, etc.).
5. **Scan de ports depuis l'extérieur** : nftables ne laisse rien
   d'autre que SSH en entrée (J2/D2), la surface d'attaque réseau est
   réduite au strict minimum.

**Ce que cette configuration ne couvre pas** : compromission d'une clé
privée admin (aucun MFA mis en place - voir pistes bonus), 0-day sur
OpenSSH lui-même, attaque depuis un compte métier compromis localement
contre d'autres comptes métier du même groupe (les ACL protègent entre
groupes, pas entre deux chercheurs par exemple), déni de service réseau
(hors périmètre du sujet).

### Fichiers SUID présents

Relevé réel sur la VM durcie (`find / -xdev -perm -4000 -type f`) :

- `/usr/bin/sudo`, `/usr/bin/su`, `/usr/bin/passwd`, `/usr/bin/chfn`,
  `/usr/bin/chsh`, `/usr/bin/gpasswd`, `/usr/bin/newgrp` : nécessaires
  à la gestion standard des comptes/mots de passe, imposés par Debian.
- `/usr/bin/mount`, `/usr/bin/umount`, `/usr/bin/fusermount3`,
  `/usr/bin/ntfs-3g` : montage de systèmes de fichiers par un utilisateur
  non privilégié (utile pour le second disque/les sauvegardes).
- `/usr/lib/openssh/ssh-keysign` : signature des clés d'hôte pour
  l'authentification SSH basée sur l'hôte (non utilisée ici, mais
  installée par défaut avec `openssh-client`).
- `/usr/lib/dbus-1.0/dbus-daemon-launch-helper`,
  `/usr/lib/polkit-1/polkit-agent-helper-1`, `/usr/bin/pkexec` : pile
  D-Bus/PolicyKit installée par défaut avec les dépendances système,
  non utilisée directement par ce projet mais présente sur une
  installation Debian standard.
- `/usr/sbin/pppd`, `/usr/lib/xorg/Xorg.wrap`,
  `/usr/bin/vmware-user-suid-wrapper` : hérités du profil d'installation
  choisi (tâche « système standard » incluant des paquets réseau/
  affichage/VMware Tools non indispensables à un serveur). **À
  reconsidérer** : sur une installation réellement minimale sans
  interface graphique, `xorg` et `pppd` ne devraient pas être présents ;
  à purger si le temps le permet (`apt purge xserver-xorg* ppp`).

Aucun binaire SUID supplémentaire n'a été ajouté par ce projet.

## 4. Procédure de restauration d'une sauvegarde

1. Identifier la version à restaurer : `ls /mnt/sauvegarde/versions/`.
2. Copier le ou les fichiers voulus depuis cette version vers leur
   emplacement d'origine, en conservant les droits :
   ```sh
   sudo rsync -aAX /mnt/sauvegarde/versions/<date>/srv/<fichier> /srv/<fichier>
   ```
3. Vérifier les droits/ACL du fichier restauré (`getfacl`).
4. Pour une restauration complète de `/srv` ou `/etc`, remplacer
   `<fichier>` par `srv/` ou `etc/` (avec un `/` final sur la source).

**Test effectué** : création d'un fichier dans `/srv/analyses`,
sauvegarde (`sauvegarde.sh`), suppression du fichier, restauration
depuis `/mnt/sauvegarde/latest/srv/analyses/` avec la commande
ci-dessus. Fichier et droits ACL retrouvés à l'identique.
