#!/bin/bash
# C1/C2 - crée comptes, groupes, répertoires /srv et ACL à partir de comptes.csv
# Idempotent : peut être relancé sans erreur ni doublon.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CSV="${1:-$SCRIPT_DIR/comptes.csv}"
KEYS_DIR="$SCRIPT_DIR/keys"

if [ "$(id -u)" -ne 0 ]; then
    echo "Ce script doit être lancé en root (sudo)." >&2
    exit 1
fi

if [ ! -f "$CSV" ]; then
    echo "Fichier comptes.csv introuvable : $CSV" >&2
    exit 1
fi

# --- Groupes métier (contexte C - BioLab) + groupes transverses ---
GROUPES=(admins support acces_ssh technique chercheurs doctorants invite)
for g in "${GROUPES[@]}"; do
    if ! getent group "$g" >/dev/null; then
        groupadd "$g"
        echo "Groupe créé : $g"
    fi
done

# --- Comptes à partir du CSV ---
tail -n +2 "$CSV" | while IFS=';' read -r login nom groupe_principal groupes_secondaires; do
    [ -z "$login" ] && continue

    shell="/bin/bash"
    if [ "$groupe_principal" = "invite" ]; then
        shell="/usr/sbin/nologin"
    fi

    if id "$login" >/dev/null 2>&1; then
        usermod -g "$groupe_principal" -c "$nom" -s "$shell" "$login"
    else
        useradd -m -c "$nom" -g "$groupe_principal" -s "$shell" "$login"
        echo "Compte créé : $login ($nom)"
    fi

    if [ -n "$groupes_secondaires" ]; then
        usermod -aG "$groupes_secondaires" "$login"
    fi

    # Clé publique de test pour les comptes acces_ssh
    if id -nG "$login" | grep -qw acces_ssh; then
        home="$(getent passwd "$login" | cut -d: -f6)"
        pubkey="$KEYS_DIR/$login.pub"
        if [ -f "$pubkey" ]; then
            mkdir -p "$home/.ssh"
            touch "$home/.ssh/authorized_keys"
            if ! grep -qF "$(cat "$pubkey")" "$home/.ssh/authorized_keys" 2>/dev/null; then
                cat "$pubkey" >> "$home/.ssh/authorized_keys"
            fi
            chmod 700 "$home/.ssh"
            chmod 600 "$home/.ssh/authorized_keys"
            chown -R "$login:$groupe_principal" "$home/.ssh"
        else
            echo "ATTENTION : pas de clé publique pour $login ($pubkey)" >&2
        fi
    fi
done

# --- Répertoires /srv et ACL (contexte C - BioLab) ---
# Répertoire               technique      chercheurs    doctorants   invite
# /srv/donnees_brutes      rw             r             r            -
# /srv/analyses            -              rw            rw           -
# /srv/publications        -              rw            r            r

set_acl() {
    # set_acl <dir> "group:perm group:perm ..."
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

mkdir -p /srv
set_acl /srv/donnees_brutes technique:rwx chercheurs:rx doctorants:rx
set_acl /srv/analyses chercheurs:rwx doctorants:rwx
set_acl /srv/publications chercheurs:rwx doctorants:rx invite:rx

echo "creer_comptes.sh terminé."
