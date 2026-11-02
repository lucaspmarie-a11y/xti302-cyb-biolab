#!/bin/bash
# J4 - rapport des connexions SSH (échecs par IP, comptes visés, connexions
# réussies). Renvoie un code de sortie != 0 si un seuil d'alerte est dépassé.
#
# Sur une Debian 13 minimale, rsyslog n'est pas installé : il n'y a pas de
# /var/log/auth.log. Les connexions SSH sont dans le journal systemd (sshd).
set -uo pipefail

SEUIL="${SEUIL:-10}"   # nombre d'échecs pour une même IP avant alerte (justifié dans DOSSIER.md)

if [ "$(id -u)" -ne 0 ]; then
    echo "Ce script doit être lancé en root (sudo)." >&2
    exit 2
fi

LOGS="$(journalctl -u ssh.service --no-pager -o short-iso 2>/dev/null)"

echo "=== Rapport analyse_logs.sh - $(date '+%Y-%m-%d %H:%M:%S') ==="
echo

echo "--- Échecs d'authentification par IP ---"
echo "$LOGS" | grep -oE 'Failed password for (invalid user )?\S+ from [0-9a-fA-F:.]+' \
    | grep -oE '[0-9a-fA-F:.]+$' \
    | sort | uniq -c | sort -rn \
    | awk '{printf "  %-20s %s tentative(s)\n", $2, $1}'
echo

echo "--- Comptes visés par des échecs ---"
echo "$LOGS" | grep -oE 'Failed password for (invalid user )?\S+ from' \
    | sed -E 's/Failed password for (invalid user )?//; s/ from$//' \
    | sort | uniq -c | sort -rn \
    | awk '{printf "  %-20s %s tentative(s)\n", $2, $1}'
echo

echo "--- Connexions réussies ---"
echo "$LOGS" | grep -E 'Accepted (publickey|password) for' \
    | sed -E 's/^.*Accepted (publickey|password) for ([^ ]+) from ([0-9a-fA-F:.]+).*/  \2 depuis \3 (\1)/'
echo

MAX_ECHECS_IP=$(echo "$LOGS" | grep -oE 'Failed password for (invalid user )?\S+ from [0-9a-fA-F:.]+' \
    | grep -oE '[0-9a-fA-F:.]+$' | sort | uniq -c | sort -rn | head -1 | awk '{print $1+0}')
MAX_ECHECS_IP="${MAX_ECHECS_IP:-0}"

echo "Seuil d'alerte : $SEUIL échecs pour une même IP (max observé : $MAX_ECHECS_IP)"

if [ "$MAX_ECHECS_IP" -ge "$SEUIL" ]; then
    echo "ALERTE : seuil dépassé."
    exit 1
fi

exit 0
