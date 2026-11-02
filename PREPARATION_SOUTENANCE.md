# Préparation soutenance - XTI302-CYB (contexte C BioLab)

Le jury peut interroger n'importe lequel des trois (Lucas, Guillaume,
Malo) sur n'importe quelle ligne, pas seulement "sa" partie. Ce document
sert de fiche de révision : lisez-le ensemble, chacun doit pouvoir
reformuler chaque réponse avec ses propres mots.

## 1. Déroulé de la soutenance (rappel du sujet)

1. **Démonstration** : `installer.sh` sur la VM reconstruite depuis le
   snapshot `vierge`, puis `verifier.sh`, puis 1-2 attaques qui échouent
   (connexion root, force brute bannie par fail2ban).
2. **Dépannage** : le jury modifie la config pendant que vous êtes
   éloignés. Vous devez retrouver quoi, avec `verifier.sh` comme
   principal outil de diagnostic.
3. **Questions individuelles** sur l'ensemble du projet.

## 2. Exercice de dépannage : méthode

`verifier.sh` teste quasiment toutes les exigences avec un code (C1,
S2, J2...). En cas de problème :

1. Lancer `sudo /usr/local/sbin/verifier.sh`, noter les `[KO]`.
2. Chaque ID `[KO]` pointe vers un seul fichier de config en général :

   | ID | Fichier à vérifier |
   |---|---|
   | C1/C2 | `comptes.csv`, sortie de `getfacl /srv/...` |
   | C3 | `/etc/sudoers.d/admins`, `/etc/sudoers.d/support` (`visudo -c`) |
   | C4 | `passwd -S root`, `stat /home/*` |
   | S1-S5 | `/etc/ssh/sshd_config.d/10-hardening.conf` (`sshd -T` pour voir la config *effective*, pas juste le fichier) |
   | J1 | `systemctl status fail2ban`, `fail2ban-client status sshd` |
   | J2 | `nft list ruleset` |
   | J3 | `/etc/systemd/journald.conf.d/10-persistent.conf` |
   | J4 | `/usr/local/sbin/analyse_logs.sh` existe/exécutable |
   | B1-B3 | `/mnt/sauvegarde` monté ? `/usr/local/sbin/sauvegarde.sh` |
   | D1 | `systemctl status unattended-upgrades` |
   | D2 | `ss -tulpn` |

3. Pour les tests SSH (S1-S5) : **toujours utiliser `sshd -T`** (config
   effective après fusion de tous les fichiers), jamais juste relire le
   fichier à l'œil - une directive dans un autre fichier de
   `sshd_config.d/` peut écraser la vôtre si chargé après (ordre
   alphabétique).
4. Après toute modif de `sshd_config.d/`, toujours `sshd -t` avant
   `systemctl reload ssh` - sinon risque de rester bloqué dehors (c'est
   justement le piège n°1 du sujet).
5. Après toute modif de `nftables.conf` : `nft -c -f /etc/nftables.conf`
   (dry-run) avant `systemctl restart nftables`.
6. Si vous êtes bloqués dehors en SSH : **la console VMware reste
   ouverte**, c'est l'accès de secours. Root y est verrouillé
   (`passwd -l`), donc il faut se connecter avec un compte admin
   existant (`lmarie`/`lmarie` etc., mot de passe local même si
   l'accès SSH est cassé) puis `sudo`.

## 3. Pannes plausibles que le jury pourrait injecter, et le fix

- **Retirer `lmarie` du groupe `acces_ssh`** → symptôme : plus
  d'accès SSH pour lui seul. Fix : `sudo usermod -aG acces_ssh lmarie`.
- **Changer `AllowGroups acces_ssh` en autre chose** ou le supprimer
  → `test_S3` KO. Fix : corriger
  `/etc/ssh/sshd_config.d/10-hardening.conf`, `sshd -t`, `reload ssh`.
- **Remettre `PermitRootLogin yes`** → `test_S2` KO. Même fix.
- **Désactiver/arrêter fail2ban** → `test_J1_actif` KO. Fix :
  `systemctl enable --now fail2ban`.
- **Changer la politique nftables en `accept`** → `test_J2_policy` KO.
  Fix : relancer `nft -f /etc/nftables.conf` (le fichier de référence
  est toujours sur le disque, pas besoin de le réécrire).
- **Démonter `/mnt/sauvegarde`** → `test_B1_versions`/`B3` KO. Fix :
  `sudo mount /mnt/sauvegarde` (entrée fstab déjà présente).
- **Modifier un fichier sudoers à la main et casser la syntaxe** →
  `visudo -c` échoue, sudo entier cassé pour tout le monde. Fix :
  éditer `/etc/sudoers.d/...` **avec `visudo -f <fichier>`** (jamais un
  éditeur classique, sinon risque de syntax error qui bloque tout sudo
  système), ou si déjà cassé, remettre le fichier depuis le dépôt Git.
- **Retirer la clé publique d'un `authorized_keys`** → ce compte ne
  peut plus se connecter. Fix : relancer `creer_comptes.sh` (idempotent,
  réinstalle les clés depuis `keys/`).
- **Changer les ACL d'un `/srv/*`** → `test_C2_*` KO. Fix : relancer
  `creer_comptes.sh`, qui réapplique `setfacl -b` puis les bonnes ACL à
  chaque fois (base propre avant réapplication).

## 4. Questions pièges probables (avec réponses)

**Pourquoi pas `set -euo pipefail` dans `verifier.sh` ?**
Le rôle de `verifier.sh` est justement de lancer des commandes qui
*doivent* pouvoir échouer sans arrêter le script (ex: `sudo -u slevy
test -w /srv/donnees_brutes` qui échoue *normalement* parce que slevy
n'a pas le droit - c'est le résultat attendu du test, pas une erreur).
Avec `set -e`, le script s'arrêterait au premier test KO au lieu de
tous les exécuter. `creer_comptes.sh`, `installer.sh`,
`analyse_logs.sh`, `sauvegarde.sh` gardent un `set -uo pipefail` ou
équivalent car leurs commandes ne sont pas censées échouer en
fonctionnement normal.

**Pourquoi ACL et pas juste des groupes Unix classiques ?**
Un répertoire Unix classique n'a qu'un seul propriétaire et un seul
groupe : on ne peut distinguer que 3 niveaux de droits (propriétaire /
groupe / autres). Le contexte C a 4 groupes avec des droits différents
sur un même répertoire (ex: `/srv/donnees_brutes` : technique rw,
chercheurs/doctorants r, invite aucun) - impossible avec les
permissions classiques seules. D'où les ACL (`setfacl`), qui
permettent plusieurs entrées groupe par fichier. Les ACL *par défaut*
(`-d`) sont nécessaires pour que les fichiers créés après coup dans
ces répertoires héritent des mêmes droits (sinon l'ACL ne s'applique
qu'aux fichiers existants au moment du `setfacl`).

**Pourquoi le masque (`mask::rwx`) dans les ACL ?**
Le masque ACL plafonne les droits effectifs de toutes les entrées
nommées (sauf propriétaire et "autres"). `setfacl` le recalcule
automatiquement à chaque `-m` pour être l'union des permissions
accordées, donc avec nos commandes il reste à `rwx` et ne limite rien
d'inattendu ici - mais c'est lui qu'il faut vérifier en premier si un
droit censé être accordé ne marche pas malgré une ACL correcte.

**Pourquoi `support` n'a droit qu'à un seul script, et pourquoi ce
script appartient à root et n'est modifiable que par lui ?**
Si `support` pouvait modifier `analyse_logs.sh`, il pourrait y mettre
n'importe quelle commande (ex: `bash`) et l'exécuter en root via
sudo - contournement total (voir GTFOBins : n'importe quel programme
autorisé en sudo sans contrôle de son contenu devient un chemin vers
un shell root). D'où `chmod 750 root:root` sur le script, et la règle
sudoers qui pointe vers un **chemin précis**, pas un nom de commande
libre.

**Pourquoi la connexion SSH par mot de passe est refusée alors que les
comptes ont quand même un mot de passe (pour sudo) ?**
Deux mécanismes différents : `PasswordAuthentication no` désactive le
mot de passe **pour l'authentification SSH initiale** uniquement (on
doit prouver son identité par clé). Le mot de passe local reste utilisé
par **sudo**, qui est un mécanisme PAM local indépendant de SSH,
déclenché après la connexion. C'est voulu : même avec une clé SSH
compromise, l'attaquant ne peut pas devenir root sans connaître aussi
le mot de passe sudo (défense en profondeur).

**Pourquoi `invite` a un shell `nologin` *et* un `ForceCommand
internal-sftp` dans sshd_config - n'est-ce pas redondant ?**
Oui, en partie redondant, et c'est voulu : `nologin` empêche toute
connexion locale ou `su - invite_user` sur la machine elle-même,
`ForceCommand internal-sftp` empêche toute commande autre que SFTP
*via SSH* même si quelqu'un changeait son shell par erreur. Deux
verrous indépendants pour la même propriété (défense en profondeur,
même logique qu'au-dessus).

**Pourquoi `ChrootDirectory /srv` pour le groupe `invite` ?**
Sans chroot, un compte SFTP peut naviguer et lister (même en lecture
seule selon permissions) l'intégralité de l'arborescence du serveur. Le
chroot le confine à `/srv`, qui est la seule zone qui le concerne. SSH
exige que `/srv` et tous les répertoires parents soient root-owned et
non inscriptibles par groupe/autres pour accepter ce chroot - d'où
`/srv` en `root:root 755` (et les sous-répertoires en `root:root 750`,
les ACL ne comptent pas dans cette vérification car `sshd` ne regarde
que les bits Unix classiques).

**Pourquoi 4 tentatives (`MaxAuthTries`) et pas moins/plus ?**
Choix libre à justifier. 4 est cohérent avec la jail fail2ban
(`maxretry = 4`) : un seul essai « raté » côté connexion SSH compte
comme une tentative vue par fail2ban ; borner les deux au même chiffre
évite qu'un attaquant reste juste sous le seuil à chaque connexion.

**Pourquoi la sauvegarde utilise `--link-dest` et pas une copie
complète à chaque fois ?**
`--link-dest=<version précédente>` dit à rsync de créer un hard-link
vers le fichier de la version précédente quand le fichier n'a pas
changé, au lieu de le recopier. Résultat : chaque version datée
*semble* complète (on peut naviguer dedans comme une copie normale),
mais l'espace disque réellement utilisé ne compte qu'une fois les
fichiers identiques entre deux versions - condition imposée par le
sujet ("incrémentale... fichiers inchangés non recopiés") tout en
gardant des versions pleinement navigables (contrairement à un rsync
`--delete` seul, qui écraserait l'ancienne version).

**Pourquoi 7 versions et pas un nombre illimité ?**
Imposé par le sujet comme minimum ("au moins les 7 dernières"). Avec un
disque de 2 Go et des données `/srv`+`/etc` limitées en pratique, 7
versions quotidiennes tiennent largement ; au-delà, purge automatique
dans `sauvegarde.sh` (`ls | sort | head -n -$KEEP`).

**fail2ban + nftables : comment les deux pare-feux coexistent ?**
fail2ban (action `nftables` sur Debian) crée sa **propre** table/chaîne
nftables, indépendante de notre table `inet filter` définie dans
`nftables.conf`. Un `systemctl restart nftables` qui recharge *notre*
fichier ne supprime pas les règles de fail2ban (chaînes séparées).
**Vérifié en conditions réelles** sur la VM : la table de fail2ban
n'apparaît qu'au moment du **premier bannissement réel** (pas juste au
démarrage du service) - `nft list ruleset` ne montre que `inet filter`
tant qu'aucune IP n'a été bannie, puis une seconde table apparaît
après un ban effectif.

**Piège réel découvert en testant (pas juste théorique) : le mode
`normal` de fail2ban ne détecte RIEN en SSH clé-seule.**
En testant J1 pour de vrai (4 tentatives avec une fausse clé depuis
l'hôte), **aucun bannissement ne s'est déclenché** avec la config
initiale (`mode` par défaut = `normal`). Cause : sur OpenSSH récent
(Debian 13), une tentative de clé refusée ne produit pas de ligne
`Failed password` (il n'y a pas de mot de passe à refuser, S1 l'a
désactivé) mais des lignes du type :
```
sshd[...]: drop connection #0 from [IP]:port on [IP]:22 penalty: failed authentication
sshd-session[...]: Connection closed by authenticating user lmarie IP port NNNN [preauth]
```
Le filtre `sshd.conf` de fail2ban classe explicitement ces fermetures
pré-authentification comme **non-échecs** (`NOFAIL`) en mode `normal`
- ce mode a été conçu à une époque où l'essentiel du bruteforce SSH
était par mot de passe. Correctif appliqué : `mode = aggressive` dans
`config/fail2ban/jail.d/sshd.conf`, qui traite ces fermetures
pré-auth comme des échecs. **Re-testé après correctif : le
bannissement se déclenche bien après 4 tentatives** (vérifié deux
fois, y compris en se bannissant soi-même par erreur).

*Pourquoi c'est une bonne question de soutenance à anticiper* : ça
montre que la conformité "sur le papier" (fail2ban installé, jail
activée, `[OK]` dans un `verifier.sh` qui ne teste que
`systemctl is-active`) ne suffit pas - il faut **tester l'attaque
réelle** pour vérifier qu'une protection fonctionne, pas seulement
qu'un service tourne. `verifier.sh` dans ce projet teste la présence
et l'activation de fail2ban (`test_J1_actif`, `test_J1_jail`), pas
l'efficacité réelle du filtre contre une vraie tentative - c'est une
limite assumée de `verifier.sh` (il ne doit jamais modifier l'état du
système ni générer de vraies tentatives d'intrusion), à mentionner
explicitement si le jury demande "comment savez-vous que ça marche
vraiment ?".

**Pourquoi se bannir soi-même est un risque (piège du sujet) ?**
Les tests de force brute pendant la démo viennent de la machine hôte
(votre PC), qui a la même IP source à chaque tentative. Après
`maxretry` (4) échecs en moins de `findtime` (10 min), fail2ban bannit
cette IP pour `bantime` (10 min) - y compris vous-même en pleine
démonstration. Savoir débannir sans attendre :
`sudo fail2ban-client set sshd unbanip <IP>`.

**Pourquoi `root` est verrouillé avec `passwd -l` et pas en désactivant
le compte (`usermod -L` fait la même chose, ou suppression) ?**
`passwd -l` (= `usermod -L`) préfixe le hash du mot de passe par `!`,
ce qui bloque toute authentification par mot de passe (console comprise)
sans supprimer le compte - root reste nécessaire pour certains
processus système (UID 0 réservé), donc le supprimer casserait le
système. Combiné à `PermitRootLogin no` (SSH) et au fait qu'aucune clé
n'est installée pour root, il n'y a plus aucun moyen de devenir root
directement : il faut passer par un compte admin + sudo.

## 5. Démo attendue - script minute par minute

1. `sudo bash installer.sh` depuis le snapshot vierge (quelques minutes,
   l'essentiel est le téléchargement des paquets).
2. `sudo verifier.sh` → 30/30.
3. Attaque 1 - connexion root refusée :
   `ssh root@192.168.179.131` → échec immédiat (`Permission denied`,
   pas de prompt mot de passe car clé seule acceptée, et root n'a pas
   de clé de toute façon).
4. Attaque 2 - force brute bannie : depuis l'hôte,
   `for i in 1 2 3 4 5; do ssh -o PreferredAuthentications=password
   nimporte_qui@192.168.179.131 true; done` → après le 4e/5e échec,
   nouvelle tentative = connexion refusée direct (IP bannie). Montrer
   `sudo fail2ban-client status sshd` (IP dans la liste "Banned").
   Démbannir avant de continuer : `fail2ban-client set sshd unbanip
   <IP hôte>`.

## 6. Ce que chacun doit absolument savoir expliquer seul

- **Lucas/Guillaume/Malo** (tous) : les 20 exigences du tableau de
  conformité (`DOSSIER.md` section 1), la logique de `verifier.sh`
  (pourquoi une fonction par test, pourquoi pas `set -e`), comment
  déboguer une panne SSH sans se bloquer dehors.
- Relire ensemble `creer_comptes.sh` ligne par ligne : la boucle CSV,
  pourquoi `IFS=';'`, pourquoi `usermod -aG` et pas `usermod -G` seul
  pour les groupes secondaires (`-G` seul *remplace* tous les groupes
  secondaires, `-aG` les *ajoute* - essentiel pour l'idempotence, sinon
  relancer le script sans `-a` retirerait `acces_ssh` à chaque fois si
  jamais on le listait différemment).
- Relire `installer.sh` dans l'ordre : pourquoi cet ordre précis
  (comptes avant sudoers, sudoers avant SSH, SSH validé par `sshd -t`
  avant `reload`, disque préparé avant le timer de sauvegarde).
