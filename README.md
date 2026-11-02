# XTI302-CYB - Durcir un serveur Linux et le prouver

Contexte choisi : **C - Laboratoire BioLab**.

Groupe : Lucas Marie, Guillaume Bazydlo, Malo Crespel.

## Prérequis

- VM Debian 13, installation minimale, serveur SSH installé.
- Second disque virtuel (1-2 Go) attaché pour les sauvegardes (`/dev/sdb`).
- Accès root sur la VM pour la première installation.

## Installation

```sh
git clone <dépôt> /opt/xti302-biolab
cd /opt/xti302-biolab
sudo ./installer.sh
```

`installer.sh` installe les paquets nécessaires, crée les comptes/groupes/
répertoires `/srv` (ACL comprises), durcit SSH, configure fail2ban,
nftables, le journal persistant, prépare le second disque et active la
sauvegarde planifiée. Il est idempotent : le relancer ne recrée pas ce qui
existe déjà et ne reformate jamais le second disque s'il contient déjà des
sauvegardes.

## Vérification

```sh
sudo /usr/local/sbin/verifier.sh
```

Affiche `[OK]`/`[KO]` pour chaque exigence du cahier des charges et un
score final. Code de sortie 0 si tout est conforme.

## Comptes

Voir `comptes.csv`. Les comptes du groupe `acces_ssh` (administrateurs,
`support`, et `invite` en SFTP) ont leur clé publique dans `keys/`,
installée automatiquement par `creer_comptes.sh`. Les clés privées de
test (`support`, `invite`) ne sont **pas** dans ce dépôt.

## Scripts

| Script | Rôle |
|---|---|
| `creer_comptes.sh` | comptes, groupes, `/srv`, ACL |
| `installer.sh` | reconstruit toute la configuration |
| `analyse_logs.sh` | rapport des connexions SSH (exécutable par `support` via sudo) |
| `sauvegarde.sh` | sauvegarde incrémentale versionnée de `/srv` et `/etc` |
| `verifier.sh` | vérification automatique de toutes les exigences |

Voir `DOSSIER.md` pour les choix techniques, la défense, et la procédure
de restauration.
