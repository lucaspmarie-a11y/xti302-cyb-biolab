# Explications détaillées - XTI302-CYB (contexte C BioLab)

Ce document explique **chaque fichier, bloc par bloc**, pour que chacun
des trois membres du groupe puisse défendre n'importe quelle ligne à
l'oral. Lisez-le avec le fichier source ouvert à côté.

---

## 0. Vue d'ensemble de l'architecture

```
comptes.csv              <- source de vérité pour les comptes
creer_comptes.sh         <- lit comptes.csv, crée comptes/groupes/ACL (C1,C2)
config/
  sudoers.d/admins       <- C3 (droits admins)
  sudoers.d/support      <- C3 (droits support, un seul script)
  ssh/sshd_config.d/     <- S1-S5 (durcissement SSH)
  fail2ban/jail.d/       <- J1 (anti-bruteforce)
  nftables.conf          <- J2 (pare-feu)
  journald.conf          <- J3 (logs persistants)
  systemd/               <- B2 (planification sauvegarde)
analyse_logs.sh           <- J4 (rapport SSH, utilisé par support)
sauvegarde.sh             <- B1 (sauvegarde incrémentale)
installer.sh               <- orchestre tout, dans l'ordre, idempotent
verifier.sh                 <- teste tout, n'écrit rien de permanent
```

**Logique générale** : `installer.sh` est le seul point d'entrée pour
construire le serveur depuis zéro. Il appelle `creer_comptes.sh`,
copie les fichiers de `config/` vers leurs emplacements système
réels (`/etc/...`), active les services, prépare le disque de
sauvegarde, et installe `verifier.sh`/`analyse_logs.sh`/`sauvegarde.sh`
dans `/usr/local/sbin/` (emplacement standard pour les scripts admin
locaux, hors des paquets Debian officiels - `/usr/local` est réservé
à ça, voir Filesystem Hierarchy Standard).

---

## 1. `comptes.csv`

```csv
login;nom;groupe_principal;groupes_secondaires
lmarie;Lucas Marie;admins;acces_ssh
...
```

- Format imposé par le sujet : `;` comme séparateur, 4 colonnes, pas
  de mot de passe dedans (les mots de passe sont définis séparément,
  localement sur la VM, jamais versionnés).
- `groupe_principal` = le groupe Unix primaire du compte (`id -gn`
  le renvoie). Chaque fichier créé par cet utilisateur appartient par
  défaut à ce groupe.
- `groupes_secondaires` = liste `,`-séparée de groupes additionnels
  (ex: `acces_ssh`). Peut être vide (ex: `jrousseau;...;technique;`
  avec rien après le dernier `;`).
- **Pourquoi `acces_ssh` est un groupe secondaire et pas le groupe
  principal** : le groupe principal d'un compte métier doit rester le
  groupe métier (`technique`, `chercheurs`...) parce que c'est lui qui
  détermine la propriété des nouveaux fichiers qu'il crée dans `/srv`.
  `acces_ssh` est seulement une étiquette d'autorisation ("a le droit
  de se connecter"), pas une identité métier - d'où secondaire.

---

## 2. `creer_comptes.sh` (C1, C2)

### En-tête

```bash
set -uo pipefail
```
- `-u` : toute variable non définie utilisée fait planter le script
  (évite par exemple d'écraser `/` si une variable de chemin est vide
  par erreur).
- `-o pipefail` : dans un pipeline `a | b`, le code de sortie reflète
  l'échec de `a` même si `b` réussit (sinon un `cat fichier_absent |
  grep x` serait vu comme un succès si `grep` ne plante pas).
- **Pas de `-e`** ici volontairement pas pour la même raison que dans
  `verifier.sh`, mais en réalité ce script-ci n'a presque aucune
  commande censée échouer "normalement" - on aurait pu mettre `-e`.
  Choix cohérent avec le reste du projet : seul `verifier.sh` a besoin
  de tolérer les échecs.

### Vérification root

```bash
if [ "$(id -u)" -ne 0 ]; then
    echo "..." >&2
    exit 1
fi
```
- `id -u` renvoie l'UID numérique de l'utilisateur courant ; root a
  toujours l'UID 0. On compare à `0`, pas au nom `"root"`, parce que
  l'UID est la seule chose garantie stable (un compte peut théoriquement
  s'appeler autrement mais garder l'UID 0).
- Message d'erreur envoyé sur `>&2` (stderr), pas stdout : convention
  Unix - stdout est pour la sortie normale du programme, stderr pour
  les diagnostics/erreurs, ce qui permet de les rediriger séparément
  (`./script.sh > log.txt` ne noierait pas les erreurs dans le log).

### Création des groupes

```bash
for g in "${GROUPES[@]}"; do
    if ! getent group "$g" >/dev/null; then
        groupadd "$g"
    fi
done
```
- `getent group "$g"` interroge la base de comptes système (fichier
  `/etc/group` ici, mais `getent` fonctionnerait aussi avec LDAP/NIS
  si configuré - bonne pratique au lieu de `grep "$g" /etc/group`)
  et renvoie du texte si le groupe existe (code 0), rien + code 2
  sinon.
- **C'est ça qui rend le script idempotent pour les groupes** : sans
  ce test, relancer `groupadd admins` une deuxième fois échouerait
  (`groupadd: le groupe « admins » existe déjà`).

### Boucle sur les comptes

```bash
tail -n +2 "$CSV" | while IFS=';' read -r login nom groupe_principal groupes_secondaires; do
```
- `tail -n +2` saute la ligne d'en-tête (`login;nom;...`) - sans ça,
  le script essaierait de créer un utilisateur nommé "login".
- `IFS=';'` change le séparateur de champs de `read` (espace par
  défaut) pour `;`, pour que `read` découpe correctement la ligne CSV
  en 4 variables.
- `read -r` : le `-r` désactive l'interprétation des `\` comme
  caractères d'échappement (sinon un nom contenant `\n` ou similar
  serait mal interprété) - bonne pratique systématique avec `read`.

```bash
shell="/bin/bash"
if [ "$groupe_principal" = "invite" ]; then
    shell="/usr/sbin/nologin"
fi
```
- Seul le groupe `invite` a un shell `nologin` : c'est la
  "particularité" du contexte C ("les membres du groupe invite n'ont
  pas de shell interactif"). `/usr/sbin/nologin` est un programme qui,
  à la place d'un vrai shell, affiche un message et quitte
  immédiatement - empêche toute connexion locale (`su - pleroy`) même
  si quelqu'un obtenait le mot de passe.

```bash
if id "$login" >/dev/null 2>&1; then
    usermod -g "$groupe_principal" -c "$nom" -s "$shell" "$login"
else
    useradd -m -c "$nom" -g "$groupe_principal" -s "$shell" "$login"
fi
```
- `id "$login"` teste l'existence du compte (code 0 si existe, 1
  sinon) ; `>/dev/null 2>&1` jette toute sortie (on ne veut que le
  code de retour).
- Si le compte existe déjà : `usermod` **met à jour** ses attributs au
  lieu de planter - c'est ce qui rend le script rejouable sans erreur
  (idempotence).
- Si nouveau : `useradd -m` crée aussi le répertoire personnel
  (`/home/login`) avec les fichiers de squelette (`/etc/skel`).
- `-c "$nom"` remplit le champ GECOS (le "vrai nom" visible par
  `finger`/`id` etc.), utile pour que `verifier.sh`/l'admin sache à
  qui appartient le compte.

```bash
if [ -n "$groupes_secondaires" ]; then
    usermod -aG "$groupes_secondaires" "$login"
fi
```
- **Le piège classique ici est `-G` sans `-a`** : `usermod -G x`
  *remplace* la liste complète des groupes secondaires par `x` (donc
  si on le relance avec une liste différente ou si l'utilisateur avait
  été ajouté manuellement à un autre groupe entre-temps, ce groupe
  disparaît). `-aG` (**a**ppend) ajoute sans retirer le reste -
  essentiel à la fois pour l'idempotence et pour ne pas effacer
  silencieusement une appartenance à un groupe ajoutée ailleurs.
- `usermod -aG` accepte une liste `g1,g2,g3` (sans espaces) en un seul
  appel, d'où `groupes_secondaires` directement tel quel depuis le
  CSV (déjà au format `,`-séparé, sans espace).

### Installation des clés SSH

```bash
if id -nG "$login" | grep -qw acces_ssh; then
```
- `id -nG` liste tous les groupes (noms, pas numéros) du compte,
  séparés par espace. `grep -qw acces_ssh` cherche le **mot entier**
  `acces_ssh` (`-w`) dans cette liste, en silence (`-q`, pas de
  sortie, seulement le code retour) - évite un faux positif si un
  groupe s'appelait par exemple `acces_sshtest`.

```bash
home="$(getent passwd "$login" | cut -d: -f6)"
```
- Récupère dynamiquement le répertoire personnel réel du compte
  depuis `/etc/passwd` (champ 6) plutôt que de supposer
  `/home/$login` - plus robuste si jamais un compte avait un home
  différent.

```bash
if ! grep -qF "$(cat "$pubkey")" "$home/.ssh/authorized_keys" 2>/dev/null; then
    cat "$pubkey" >> "$home/.ssh/authorized_keys"
fi
```
- `grep -qF` : recherche la clé **comme chaîne littérale** (`-F`,
  "fixed string"), pas comme expression régulière - une clé publique
  contient des caractères comme `+`/`/` qui ont un sens spécial en
  regex et casseraient une recherche `grep` normale.
- Ce test évite d'ajouter la même clé en double si on relance le
  script (idempotence encore).

```bash
chmod 700 "$home/.ssh"
chmod 600 "$home/.ssh/authorized_keys"
```
- SSH **refuse d'utiliser** `authorized_keys` si les permissions sont
  trop larges (c'est une vérification de sécurité intégrée à `sshd`,
  pas une option qu'on choisit) : le répertoire `.ssh` ne doit être
  accessible qu'au propriétaire (`700`), le fichier de clés aussi
  (`600`), sinon un autre utilisateur du système pourrait en théorie y
  ajouter sa propre clé et usurper le compte.

### Répertoires `/srv` et ACL

```bash
set_acl() {
    local dir="$1"; shift
    mkdir -p "$dir"
    chown root:root "$dir"
    chmod 750 "$dir"
    setfacl -b "$dir"
    for entry in "$@"; do
        group="${entry%%:*}"
        perm="${entry##*:}"
        setfacl -m "g:$group:$perm" "$dir"
        setfacl -d -m "g:$group:$perm" "$dir"
    done
    setfacl -m "g:admins:rwx" "$dir"
    setfacl -d -m "g:admins:rwx" "$dir"
}
```
- `chown root:root` + `chmod 750` : base restrictive - seul root (et
  les ACL ajoutées ensuite) a accès, "autres" (`other`) n'a rien
  (`750` = `rwxr-x---`, donc même le groupe `root` n'a que lecture/
  traversée, et "autres" n'a rien du tout).
- `setfacl -b "$dir"` : **b**lanchit/retire toutes les ACL existantes
  avant d'en remettre - rend la fonction idempotente et sûre à
  rappeler même si les ACL ont été modifiées entre-temps (par exemple
  par le jury pendant le dépannage) : on repart toujours d'un état
  propre et connu.
- `"${entry%%:*}"` / `"${entry##*:}"` : manipulation de chaînes Bash
  pures (pas besoin de `cut`/`awk`) - `%%:*` retire tout à partir du
  premier `:` (donne la partie avant), `##*:` retire tout jusqu'au
  dernier `:` (donne la partie après). Pour `"chercheurs:rwx"`, ça
  donne `group=chercheurs`, `perm=rwx`.
- `setfacl -m "g:$group:$perm" "$dir"` : ajoute une entrée ACL
  nommée pour ce groupe sur le répertoire *actuel*.
- `setfacl -d -m ...` (**d**efault) : la même entrée, mais comme ACL
  **par défaut** - elle ne s'applique pas au répertoire lui-même une
  deuxième fois, elle s'applique **automatiquement à tout fichier ou
  sous-répertoire créé plus tard** à l'intérieur. C'est la réponse
  directe à l'exigence du sujet : "les droits doivent aussi s'appliquer
  aux fichiers créés plus tard (ACL par défaut)".
- `admins` reçoit toujours `rwx` sur tout, en plus des groupes métier
  - cohérent avec C3 (les admins ont tous les droits) et pratique pour
  la maintenance.

```bash
set_acl /srv/donnees_brutes technique:rwx chercheurs:rx doctorants:rx
set_acl /srv/analyses chercheurs:rwx doctorants:rwx
set_acl /srv/publications chercheurs:rwx doctorants:rx invite:rx
```
- Reproduction directe du tableau du sujet (contexte C). Remarquez
  qu'`invite` n'apparaît que sur `/srv/publications` - sur les deux
  autres répertoires, l'absence d'entrée ACL pour `invite` signifie
  qu'il hérite du comportement par défaut (`other::---` posé plus
  haut), donc aucun accès.

---

## 3. `config/sudoers.d/admins` et `config/sudoers.d/support` (C3)

```
%admins ALL=(ALL:ALL) ALL
```
- `%admins` : le `%` indique un **groupe** Unix, pas un utilisateur.
- `ALL=(ALL:ALL) ALL` se lit : sur **n'importe quelle machine** (1er
  `ALL`, utile seulement si ce fichier sudoers était partagé entre
  plusieurs machines), en tant que **n'importe quel utilisateur et
  n'importe quel groupe cible** (`ALL:ALL` - par défaut `sudo cmd`
  s'exécute en root, mais `sudo -u autre cmd` serait aussi permis),
  **n'importe quelle commande** (dernier `ALL`).

```
support ALL=(root) NOPASSWD: /usr/local/sbin/analyse_logs.sh
```
- `support` (sans `%`) : un utilisateur précis, pas un groupe.
- `(root)` : seulement en tant que root (pas "n'importe quel
  utilisateur cible" comme pour admins) - support ne doit même pas
  pouvoir faire `sudo -u lmarie analyse_logs.sh` par exemple (pas
  qu'un risque réel ici, mais principe de moindre privilège strict).
- `NOPASSWD:` : support n'a pas besoin de taper son mot de passe pour
  cette commande précise - utile si `analyse_logs.sh` doit être
  lancé automatiquement (cron, supervision) sans interaction.
- `/usr/local/sbin/analyse_logs.sh` : un **chemin absolu complet**, pas
  juste un nom de commande. C'est la clé de la sécurité de cette
  règle : sudo compare le chemin exact que l'utilisateur tape. Si on
  avait juste écrit `analyse_logs.sh`, un `support` malveillant aurait
  pu créer son propre fichier `analyse_logs.sh` ailleurs dans son
  `PATH` et l'exécuter en root. Avec un chemin absolu, seul **ce**
  fichier précis (appartenant à root, non modifiable par support -
  voir `installer.sh` `install -m 750 -o root -g root`) peut être
  lancé.
- **Pourquoi `visudo -c` après la copie** (dans `installer.sh`) :
  `visudo -c` valide la syntaxe de tous les fichiers sudoers sans les
  appliquer "en live" de façon dangereuse. Une erreur de syntaxe dans
  un fichier sudoers peut casser `sudo` pour **tout le monde** y
  compris root - d'où l'importance de toujours passer par `visudo`
  (jamais `echo "..." > /etc/sudoers.d/x` suivi d'un simple test après
  coup : `visudo -c` doit se faire sur le fichier final avant de
  considérer le déploiement terminé).

---

## 4. `config/ssh/sshd_config.d/10-hardening.conf` (S1-S5)

```
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
```
- `PasswordAuthentication no` : refuse l'authentification par mot de
  passe classique (S1).
- `KbdInteractiveAuthentication no` : refuse aussi l'authentification
  "interactive" (type PAM conversationnel), qui pourrait sinon servir
  de porte dérobée équivalente à un mot de passe si PAM est configuré
  pour accepter un mot de passe via ce mécanisme alternatif - sans
  cette ligne, désactiver `PasswordAuthentication` seul ne suffit pas
  toujours selon la configuration PAM du système.
- `PubkeyAuthentication yes` : explicite (c'est la valeur par défaut,
  mais on la pose explicitement pour que la configuration soit
  auto-documentée et ne dépende pas d'une valeur implicite qui
  pourrait changer).

```
PermitRootLogin no
```
- S2. `no` (et pas `prohibit-password`, qui est le défaut Debian et
  qui permettrait quand même une connexion root **par clé**) : ici on
  veut interdire root **complètement**, par n'importe quelle méthode.

```
AllowGroups acces_ssh
```
- S3. Liste blanche par groupe : seuls les membres du groupe
  `acces_ssh` peuvent **même commencer** une tentative
  d'authentification SSH - toute autre personne est rejetée avant
  même de pouvoir essayer une clé, ce qui réduit aussi la surface
  d'attaque/le bruit dans les logs.

```
MaxAuthTries 4
ClientAliveInterval 300
ClientAliveCountMax 3
```
- S4. `MaxAuthTries 4` : nombre de tentatives d'authentification
  **par connexion TCP** (pas globalement) avant que sshd ferme la
  connexion.
- `ClientAliveInterval 300` + `ClientAliveCountMax 3` : sshd envoie un
  "ping" protocolaire toutes les 300 s (5 min) ; si 3 pings de suite
  restent sans réponse (15 min au total), la session est fermée. C'est
  le mécanisme qui réalise "session inactive fermée au bout de 15
  minutes au plus" - **ce n'est pas un vrai timeout d'inactivité
  utilisateur** (le shell peut tourner un calcul sans taper au
  clavier sans être coupé), c'est un timeout de **non-réponse réseau**
  au niveau protocole SSH, la méthode standard recommandée pour ça.

```
Match Group invite
    ForceCommand internal-sftp
    ChrootDirectory /srv
    AllowTcpForwarding no
    X11Forwarding no
    PermitTunnel no
```
- `Match Group invite` : tout ce qui suit, jusqu'au prochain `Match`
  ou la fin du fichier, ne s'applique **qu'aux connexions dont
  l'utilisateur est dans le groupe `invite`** - les autres blocs
  au-dessus s'appliquent à tout le monde.
- `ForceCommand internal-sftp` : quelle que soit la commande demandée
  par le client SSH (même un simple `ssh ... whoami`), le serveur
  exécute **toujours** `internal-sftp` à la place - empêche tout shell
  ou toute commande arbitraire, même si le shell système du compte
  n'était pas `nologin`. `internal-sftp` est un sous-système SFTP
  implémenté **dans le binaire sshd lui-même**, pas un programme
  externe - plus sûr qu'un `sftp-server` externe car pas de `fork`/
  `exec` séparé.
- `ChrootDirectory /srv` : après authentification, le processus est
  enfermé (`chroot()`) dans `/srv` - il ne voit littéralement plus
  rien en dehors, même avec `../../etc/passwd`. **Condition stricte
  de sshd** : `/srv` et tous ses parents doivent appartenir à root et
  ne pas être inscriptibles par groupe/autres (vérifié par les bits
  Unix classiques, pas les ACL) - sinon sshd refuse de démarrer la
  session avec une erreur de type "bad ownership or modes".
- `AllowTcpForwarding no`, `X11Forwarding no`, `PermitTunnel no` :
  désactivent les usages détournés de la connexion SSH (rebond réseau,
  affichage graphique distant, tunnel VPN-like) - inutiles pour un
  usage SFTP et qui élargiraient la surface d'attaque si le compte
  `invite` était compromis.

---

## 5. `config/fail2ban/jail.d/sshd.conf` (J1)

```
[sshd]
enabled = true
port = ssh
backend = systemd
mode = aggressive
maxretry = 4
findtime = 10m
bantime = 10m
```
- `[sshd]` : fail2ban fournit par défaut un filtre nommé `sshd`
  (`/etc/fail2ban/filter.d/sshd.conf`, fichier du paquet, pas le
  nôtre) qui sait reconnaître les lignes de log liées à l'auth SSH ;
  notre fichier dans `jail.d/` ne fait qu'**activer et paramétrer**
  cette jail, sans réécrire le filtre.
- `backend = systemd` : indique à fail2ban de lire les logs via
  `journalctl` plutôt qu'un fichier texte classique (`/var/log/
  auth.log`) - nécessaire ici car Debian 13 minimal n'a pas rsyslog
  installé, tout passe par le journal systemd (voir la note dans
  `analyse_logs.sh` sur ce même sujet).
- `mode = aggressive` : **le point le plus important et le moins
  évident de toute la config fail2ban.** Expliqué en détail dans
  `PREPARATION_SOUTENANCE.md` section 4 et dans `DOSSIER.md` -
  résumé : avec SSH en clé uniquement, il n'y a jamais de ligne
  `Failed password`, seulement des connexions fermées en
  pré-authentification ; le mode `normal` par défaut de fail2ban
  classe explicitement ces fermetures comme "pas un échec" (pensé à
  l'origine pour le bruteforce par mot de passe). `aggressive` les
  compte comme des échecs. **Vérifié empiriquement** sur la VM : sans
  cette ligne, 4 tentatives de clé invalide ne déclenchaient aucun
  bannissement.
- `maxretry = 4` / `findtime = 10m` / `bantime = 10m` : 4 échecs en
  une fenêtre glissante de 10 minutes déclenchent un ban de 10
  minutes. Choix cohérent avec `MaxAuthTries 4` du sshd.

---

## 6. `config/nftables.conf` (J2)

```
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        iif "lo" accept
        ct state established,related accept
        ct state invalid drop

        icmp type echo-request accept
        icmpv6 type { ... } accept

        tcp dport 22 accept
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}
```
- `#!/usr/sbin/nft -f` : permet de rendre le fichier directement
  exécutable (`./nftables.conf`) en plus d'être chargé par
  `nft -f fichier` ou par le service `nftables.service` (qui charge
  `/etc/nftables.conf` par défaut au démarrage).
- `flush ruleset` : vide toute règle existante avant de redéfinir la
  nôtre - évite l'accumulation de règles dupliquées si on recharge le
  fichier plusieurs fois (important pour l'idempotence d'`installer.sh`,
  même si, comme vu plus haut, ça ne touche pas la table séparée créée
  par fail2ban).
- `table inet filter` : `inet` = la table s'applique à la fois à IPv4
  et IPv6 en une seule définition (pas besoin de dupliquer `ip
  filter` + `ip6 filter`).
- `chain input { type filter hook input priority 0; policy drop; }` :
  cette chaîne s'accroche au point d'entrée du trafic destiné à la
  machine elle-même (`hook input`), avec une politique par défaut
  `drop` - **tout ce qui n'est pas explicitement autorisé plus bas est
  rejeté silencieusement**. C'est la base de "tout refusé par défaut,
  sauf...".
- `iif "lo" accept` : autorise tout le trafic sur l'interface loopback
  (`lo`, c'est-à-dire `127.0.0.1`/`::1`) - sans ça, des services
  locaux essentiels (ex: certains outils système qui se connectent à
  eux-mêmes) casseraient.
- `ct state established,related accept` : `ct` = **c**onnection
  **t**racking (le suivi de connexion du noyau). Une connexion
  "established" est une réponse à une connexion qu'**on** a initiée
  depuis cette machine (ex: la machine elle-même faisant une requête
  sortante) - sans cette règle, même les réponses à nos propres
  requêtes sortantes seraient bloquées par la politique `drop` en
  entrée, ce qui casserait tout (DNS, `apt update`, etc.). "related"
  couvre des connexions logiquement liées (ex: erreurs ICMP en réponse
  à une connexion existante).
- `ct state invalid drop` : rejette les paquets que le noyau ne sait
  pas rattacher à une connexion cohérente (souvent symptôme de scan de
  port ou de paquets malformés) - défense supplémentaire au-delà du
  simple `policy drop`.
- `tcp dport 22 accept` : **la seule porte ouverte volontairement** -
  SSH, conformément à D2 ("aucun service joignable en dehors de
  SSH").
- `chain forward { ... policy drop; }` : cette VM ne doit jamais
  servir de routeur entre deux réseaux - tout trafic qui ne nous est
  pas destiné mais traverserait la machine est rejeté (chaîne
  généralement vide de trafic ici puisque ce n'est pas un routeur,
  mais la politique `drop` est une sécurité par défaut correcte).
- `chain output { ... policy accept; }` : on ne restreint pas le
  trafic **sortant** initié par la machine elle-même (mises à jour,
  requêtes DNS, etc.) - un pare-feu sortant strict serait une
  exigence différente, hors du périmètre fixé par le sujet
  ("Aucun service n'est joignable **depuis le réseau**" = trafic
  entrant).

---

## 7. `config/journald.conf` (J3)

```
[Journal]
Storage=persistent
```
- Par défaut sur une install Debian minimale, `Storage=auto` : le
  journal n'est écrit sur disque (`/var/log/journal/`) que si ce
  répertoire existe déjà - sinon tout reste en RAM
  (`/run/log/journal/`) et **disparaît au redémarrage**. `persistent`
  force l'écriture sur disque et crée le répertoire si besoin (voir
  `mkdir -p /var/log/journal` dans `installer.sh`, qui s'assure que
  le répertoire existe même si on comptait sur le comportement
  automatique de `systemd-journald` au premier démarrage avec ce
  réglage).
- Nécessaire pour J4 : `analyse_logs.sh` doit pouvoir analyser
  l'historique des connexions, pas seulement depuis le dernier
  redémarrage.

---

## 8. `analyse_logs.sh` (J4)

```bash
LOGS="$(journalctl -u ssh.service --no-pager -o short-iso 2>/dev/null)"
```
- `-u ssh.service` : filtre uniquement les messages du service SSH
  (pas tout le journal système).
- `--no-pager` : empêche `journalctl` d'ouvrir un pager interactif
  (`less`) qui bloquerait un script non-interactif.
- `-o short-iso` : format de sortie avec horodatage ISO, plus facile à
  parser/trier que le format par défaut.

```bash
echo "$LOGS" | grep -oE 'Failed password for (invalid user )?\S+ from [0-9a-fA-F:.]+' \
    | grep -oE '[0-9a-fA-F:.]+$' \
    | sort | uniq -c | sort -rn
```
- Premier `grep -oE` : extrait seulement la portion de ligne qui
  matche le motif (`-o`, **o**nly matching), pas la ligne entière -
  isole `Failed password for ... from <IP>`.
- `(invalid user )?` : rend ce groupe optionnel (`?`) - couvre à la
  fois "Failed password for root from X" (compte existant) et "Failed
  password for invalid user toto from X" (compte inexistant).
- `[0-9a-fA-F:.]+` : motif volontairement large pour matcher aussi
  bien une IPv4 (`192.168.179.1`) qu'une IPv6 (contient des `:` et des
  caractères hexadécimaux).
- Deuxième `grep -oE '...$'` : ré-extrait seulement l'IP en fin de
  ligne (le `$` ancre à la fin), pour ne garder que l'adresse.
- `sort | uniq -c | sort -rn` : trie les IP, les compte (`uniq -c`),
  puis retrie par nombre décroissant (`-rn`, **r**everse **n**umeric)
  - classique pour un "top N" en shell.
- **Limite assumée, à savoir expliquer** : ce script cherche la chaîne
  littérale `Failed password`, qui (comme expliqué pour fail2ban)
  **n'apparaît jamais** sur ce serveur puisque l'authentification par
  mot de passe est désactivée (S1). En pratique sur cette VM
  durcie, ce rapport particulier restera donc souvent vide, et c'est
  **normal, pas un bug** : l'essentiel du trafic d'attaque réel
  ressemblerait plutôt aux lignes `drop connection ... penalty` vues
  lors du test de fail2ban. Si on voulait aller plus loin, on
  adapterait les expressions régulières de ce script à ces formats
  modernes - piste de bonus mentionnée mais non implémentée, à
  assumer clairement si le jury pose la question ("votre script
  détecterait-il une vraie attaque par clé ? / pourquoi le filtre
  cherche `Failed password` alors que le mot de passe est désactivé ?").

```bash
MAX_ECHECS_IP=$(... | head -1 | awk '{print $1+0}')
MAX_ECHECS_IP="${MAX_ECHECS_IP:-0}"
```
- `awk '{print $1+0}'` : force la conversion en nombre (`+0`) - si la
  recherche ne trouve rien, `$1` serait vide, et un test numérique sur
  une chaîne vide planterait le script ; `+0` convertit toute valeur
  vide/non numérique en `0` proprement.
- `"${MAX_ECHECS_IP:-0}"` : filet de sécurité supplémentaire - si la
  variable est vide malgré tout (ex: `head -1` sur une entrée vide),
  on force `0` plutôt que de comparer une chaîne vide dans le `if`
  suivant (qui ferait planter `[ -ge ]` avec une erreur de syntaxe
  shell).

---

## 9. `sauvegarde.sh` (B1, B2)

```bash
if ! mountpoint -q "$BACKUP_ROOT"; then
    echo "..." >&2
    exit 1
fi
```
- `mountpoint -q` vérifie que `$BACKUP_ROOT` est bien un point de
  montage actif (pas juste un répertoire vide sur le disque système)
  - évite une erreur sournoise où le second disque ne serait pas
  monté (ex: après un redémarrage sans `/etc/fstab` correct) et où le
  script écrirait silencieusement la "sauvegarde" sur le disque
  principal, dans un répertoire vide `/mnt/sauvegarde` - remplissant le
  disque système au lieu du disque dédié, sans message d'erreur
  visible autrement.

```bash
LINK_DEST_ARGS=()
if [ -L "$LATEST_LINK" ] && [ -d "$LATEST_LINK" ]; then
    LINK_DEST_ARGS=(--link-dest="$LATEST_LINK")
fi
rsync -aAX "${LINK_DEST_ARGS[@]}" /etc "$DEST/" >> "$LOG" 2>&1
```
- `[ -L "$LATEST_LINK" ]` : vrai seulement si c'est un lien symbolique
  (pas un fichier normal) ; `[ -d "$LATEST_LINK" ]` : vrai si ce lien
  pointe vers un répertoire existant (donc un lien symbolique "cassé"
  pointant vers un répertoire supprimé échouerait ce test). Ensemble :
  "il existe une sauvegarde précédente valide".
- `LINK_DEST_ARGS=()` puis conditionnellement rempli : technique Bash
  classique pour construire une liste d'arguments optionnels - au
  premier lancement (pas de version précédente), `rsync` tourne sans
  `--link-dest` (sauvegarde complète, normal pour la toute première
  fois).
- `--link-dest=<version précédente>` : **c'est tout le mécanisme
  d'incrémentalité du script.** Pour chaque fichier, `rsync` compare
  avec le fichier correspondant dans `$LATEST_LINK` ; s'il est
  identique, au lieu de le copier, `rsync` crée un **hard link**
  (`ln`, pas une copie) vers le fichier de l'ancienne version. Un hard
  link ne consomme quasiment aucun espace disque supplémentaire (c'est
  juste une deuxième entrée de répertoire pointant vers le même
  contenu sur le disque), donc 7 versions "complètes" de `/etc`+`/srv`
  ne coûtent en réalité que l'espace des fichiers **réellement
  modifiés** entre deux versions.
- `-a` (archive) : raccourci qui active `-rlptgoD` (récursif, préserve
  liens symboliques, permissions, timestamps, groupe, propriétaire,
  fichiers spéciaux).
- `-A` : préserve les ACL (exigence explicite du sujet : "les droits
  et les ACL sont conservés").
- `-X` : préserve les attributs étendus (xattrs) - pas strictement
  demandé par le sujet mais cohérent avec "préserver les droits" au
  sens large, et ne coûte rien.
- `ln -sfn "$DEST" "$LATEST_LINK"` : met à jour le lien `latest` vers
  la version qu'on vient de créer, pour que la **prochaine** exécution
  utilise celle-ci comme référence `--link-dest`. `-f` (force, écrase
  le lien existant), `-n` (traite `$LATEST_LINK` comme le lien
  lui-même à remplacer, pas comme un répertoire dans lequel créer un
  nouveau lien - sans `-n`, si `$LATEST_LINK` existe déjà et pointe
  vers un répertoire, `ln -s` créerait un lien **à l'intérieur** de ce
  répertoire au lieu de remplacer le lien lui-même).

```bash
NB=$(ls -1 | wc -l)
if [ "$NB" -gt "$KEEP" ]; then
    ls -1 | sort | head -n -"$KEEP" | while read -r old; do
        rm -rf "${old:?}"
    done
fi
```
- `head -n -"$KEEP"` : la syntaxe `-N` négative de `head` affiche
  **tout sauf les N dernières lignes** - combiné à `sort` (ordre
  alphabétique = ordre chronologique puisque les noms de version sont
  des horodatages `YYYYMMDD-HHMMSS`), ça donne exactement "toutes les
  versions sauf les 7 plus récentes" = celles à supprimer.
- `"${old:?}"` : syntaxe de garde-fou Bash - si `$old` était vide
  (ne devrait jamais arriver ici, mais défense en profondeur), cette
  expression fait **planter le script avec une erreur explicite**
  plutôt que d'exécuter silencieusement `rm -rf ""`, qui dans certains
  contextes shell pourrait être interprété dangereusement selon le
  répertoire courant. Règle générale à connaître : **ne jamais écrire
  `rm -rf "$variable"` sans ce genre de protection** quand la variable
  vient d'une boucle ou d'un calcul.

---

## 10. `installer.sh`

L'ordre des étapes n'est **pas arbitraire** - chaque étape dépend
souvent de la précédente :

1. **Paquets** avant tout : rien d'autre ne peut fonctionner sans
   `acl`, `rsync`, `fail2ban`, etc. installés.
2. **Comptes/groupes/ACL** avant **sudoers** : les règles sudoers
   référencent le groupe `%admins`, qui doit exister avant que
   `visudo -c` ait un sens complet (même si `visudo -c` ne vérifie que
   la syntaxe, pas l'existence du groupe - mais logiquement les
   comptes doivent exister avant qu'on puisse leur donner des droits).
3. **Sudoers** avant **verrouillage de root** : si jamais quelque
   chose tournait mal entre ces deux étapes, mieux vaut que les admins
   aient déjà sudo opérationnel avant que root devienne inutilisable.
4. **SSH validé (`sshd -t`) avant `systemctl reload ssh`** : toujours
   tester la syntaxe d'une config avant de l'appliquer en vrai - un
   `reload` avec une config cassée peut laisser sshd dans un état
   instable ou refuser de recharger (selon la gravité de l'erreur),
   avec le risque de rester bloqué dehors à la prochaine coupure de
   connexion.
5. **Disque de sauvegarde préparé avant la planification (`timer`)** :
   le timer ne doit démarrer qu'une fois `/mnt/sauvegarde` monté et
   accessible, sinon la première exécution automatique échouerait.
6. **`verifier.sh` installé en dernier** : logique, on ne peut
   vérifier que ce qui a déjà été mis en place.

### Le piège du second disque (idempotence)

```bash
if [ -b "$BACKUP_PART" ]; then
    echo "Partition $BACKUP_PART déjà présente, pas de reformatage."
else
    parted -s "$BACKUP_DISK" mklabel gpt mkpart primary ext4 1MiB 100%
    mkfs.ext4 -F -L sauvegarde "$BACKUP_PART"
fi
```
- `[ -b "$BACKUP_PART" ]` : teste si `/dev/sdb1` existe en tant que
  périphérique **b**loc. Si oui, on considère le disque déjà préparé
  et on **ne touche à rien** - directement la réponse au piège
  explicitement mentionné dans le sujet ("Que deviennent vos
  sauvegardes s'il reformate le disque à chaque exécution ?") :
  sans ce test, relancer `installer.sh` **effacerait toutes les
  sauvegardes existantes** à chaque fois.

---

## 11. `verifier.sh`

Déjà largement couvert dans `PREPARATION_SOUTENANCE.md` section 4
(pourquoi pas `set -e`, structure `ok`/`ko`, pourquoi des chemins de
repli pour `comptes.csv`/`DOSSIER.md`). Points complémentaires :

```bash
trap cleanup EXIT
```
- `trap` enregistre une fonction à exécuter automatiquement quand le
  script se termine, **quelle que soit la raison** (fin normale, `exit`
  explicite, erreur) - garantit que les fichiers de test temporaires
  (`TMPFILES`) sont toujours supprimés, même si un test échoue en
  cours de route, conformément à l'exigence du sujet ("il ne modifie
  jamais le système, sauf fichiers de test temporaires, supprimés à la
  fin").

```bash
for t in test_C1 test_C2_donnees_brutes ... ; do
    "$t"
done
```
- Chaque nom de fonction est stocké comme une chaîne, puis `"$t"`
  l'exécute comme une commande - technique standard en Bash pour
  appeler dynamiquement une liste de fonctions sans dupliquer le code
  d'appel, et qui rend très facile d'ajouter un nouveau test (il
  suffit d'écrire la fonction `test_XX` et de l'ajouter à cette liste).

```bash
echo "--- $PASS / $((PASS+FAIL)) tests réussis"
[ "$FAIL" -eq 0 ]
```
- La toute dernière ligne du script, sans `exit` explicite : le code
  de sortie du script est **celui de la dernière commande exécutée**.
  `[ "$FAIL" -eq 0 ]` renvoie 0 (vrai) si aucun test n'a échoué, 1
  sinon - exactement l'exigence du sujet ("code de sortie 0 si tout
  est conforme, 1 sinon"), sans avoir besoin d'un `if`/`exit`
  explicite à la fin.

---

## 12. Pour aller plus loin si le jury pousse

- **"Que se passe-t-il si on supprime `/etc/sudoers.d/admins` à la
  main pendant que vous êtes connectés ?"** → rien d'immédiat pour la
  session déjà ouverte (sudo garde l'accès en cache quelques minutes
  par défaut via `timestamp_timeout`), mais toute **nouvelle**
  invocation de `sudo` par un admin échouerait. Il faudrait recopier
  le fichier depuis le dépôt Git (`installer.sh` le referait aussi).
- **"Pourquoi ne pas avoir mis `NOPASSWD` pour les admins aussi ?"**
  → principe de moindre surprise/défense en profondeur : une session
  SSH compromise (vol de clé) ne suffit pas seule à agir en root, il
  faut aussi le mot de passe local - ce n'était pas imposé par le
  sujet, mais c'est un choix de sécurité assumé et justifiable.
- **"Le compte `invite` peut-il quand même lire `/etc/passwd` ou
  d'autres fichiers sensibles via le chroot SFTP ?"** → non, le
  `ChrootDirectory /srv` l'enferme entièrement dans `/srv` : il ne
  voit littéralement aucun fichier hors de cette arborescence, et à
  l'intérieur, les ACL limitent encore à `/srv/publications` en
  lecture seule.
