#!/bin/bash
# B1/B2 - sauvegarde incrémentale de /srv et /etc sur le second disque,
# versions datées, conserve les 7 dernières, droits/ACL préservés.
set -uo pipefail

BACKUP_ROOT="/mnt/sauvegarde"
KEEP=7
LOG="/var/log/sauvegarde.log"
DATE="$(date +%Y%m%d-%H%M%S)"
DEST="$BACKUP_ROOT/versions/$DATE"
LATEST_LINK="$BACKUP_ROOT/latest"

if [ "$(id -u)" -ne 0 ]; then
    echo "Ce script doit être lancé en root (sudo)." >&2
    exit 1
fi

if ! mountpoint -q "$BACKUP_ROOT"; then
    echo "Le second disque n'est pas monté sur $BACKUP_ROOT." >&2
    exit 1
fi

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"
    logger -t sauvegarde "$*"
}

mkdir -p "$BACKUP_ROOT/versions"
mkdir -p "$DEST"

LINK_DEST_ARGS=()
if [ -L "$LATEST_LINK" ] && [ -d "$LATEST_LINK" ]; then
    LINK_DEST_ARGS=(--link-dest="$LATEST_LINK")
fi

log "Début sauvegarde -> $DEST"

# -a : archive (préserve droits/propriétaire/dates) ; -A : ACL ; -X : xattrs
rsync -aAX "${LINK_DEST_ARGS[@]}" /etc "$DEST/" >> "$LOG" 2>&1
rsync -aAX "${LINK_DEST_ARGS[@]}" /srv "$DEST/" >> "$LOG" 2>&1
RC=$?

ln -sfn "$DEST" "$LATEST_LINK"

# Purge : ne garde que les $KEEP dernières versions
cd "$BACKUP_ROOT/versions" || exit 1
NB=$(ls -1 | wc -l)
if [ "$NB" -gt "$KEEP" ]; then
    ls -1 | sort | head -n -"$KEEP" | while read -r old; do
        log "Suppression ancienne version : $old"
        rm -rf "${old:?}"
    done
fi

if [ "$RC" -eq 0 ]; then
    log "Sauvegarde terminée avec succès ($DATE)."
else
    log "Sauvegarde terminée avec des erreurs (code $RC)."
fi

exit "$RC"
