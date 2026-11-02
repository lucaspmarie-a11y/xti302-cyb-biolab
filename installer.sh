#!/bin/bash
# installer.sh - reconstruit toute la configuration sur une VM Debian 13
# fraîchement installée (contexte C - BioLab, XTI302-CYB).
# Idempotent : peut être relancé sans danger (ne reformate jamais le
# second disque si une sauvegarde existe déjà dessus).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/config"
BACKUP_DISK="/dev/sdb"
BACKUP_PART="/dev/sdb1"
BACKUP_ROOT="/mnt/sauvegarde"

if [ "$(id -u)" -ne 0 ]; then
    echo "Ce script doit être lancé en root (sudo)." >&2
    exit 1
fi

echo "=== 1. Paquets ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq openssh-server acl rsync fail2ban nftables \
    unattended-upgrades sudo

echo "=== 2. Comptes, groupes, /srv, ACL (C1/C2) ==="
bash "$SCRIPT_DIR/creer_comptes.sh" "$SCRIPT_DIR/comptes.csv"

echo "=== 3. sudoers (C3) ==="
install -m 440 -o root -g root "$CONFIG/sudoers.d/admins" /etc/sudoers.d/admins
install -m 440 -o root -g root "$CONFIG/sudoers.d/support" /etc/sudoers.d/support
visudo -c

echo "=== 4. Verrouillage root, droits home (C4) ==="
passwd -l root
for h in /home/*; do
    [ -d "$h" ] && chmod 750 "$h"
done

echo "=== 5. Durcissement SSH (S1-S5) ==="
install -m 644 -o root -g root "$CONFIG/ssh/sshd_config.d/10-hardening.conf" \
    /etc/ssh/sshd_config.d/10-hardening.conf
sshd -t
systemctl reload ssh

echo "=== 6. fail2ban (J1) ==="
install -m 644 -o root -g root "$CONFIG/fail2ban/jail.d/sshd.conf" \
    /etc/fail2ban/jail.d/sshd.conf
systemctl enable --now fail2ban
systemctl restart fail2ban

echo "=== 7. nftables (J2) ==="
install -m 644 -o root -g root "$CONFIG/nftables.conf" /etc/nftables.conf
nft -c -f /etc/nftables.conf
systemctl enable nftables
systemctl restart nftables

echo "=== 8. journal persistant (J3) ==="
mkdir -p /etc/systemd/journald.conf.d
install -m 644 -o root -g root "$CONFIG/journald.conf" \
    /etc/systemd/journald.conf.d/10-persistent.conf
mkdir -p /var/log/journal
systemctl restart systemd-journald

echo "=== 9. analyse_logs.sh (J4) ==="
install -m 750 -o root -g root "$SCRIPT_DIR/analyse_logs.sh" \
    /usr/local/sbin/analyse_logs.sh

echo "=== 10. mises à jour automatiques (D1) ==="
echo 'Unattended-Upgrade::Origins-Pattern {
	"origin=Debian,codename=${distro_codename},label=Debian-Security";
};' > /etc/apt/apt.conf.d/51unattended-upgrades-security
echo 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";' > /etc/apt/apt.conf.d/20auto-upgrades
systemctl enable --now unattended-upgrades

echo "=== 11. second disque de sauvegarde (B1, autonomie) ==="
if [ -b "$BACKUP_PART" ]; then
    echo "Partition $BACKUP_PART déjà présente, pas de reformatage."
else
    parted -s "$BACKUP_DISK" mklabel gpt mkpart primary ext4 1MiB 100%
    sleep 1
    mkfs.ext4 -F -L sauvegarde "$BACKUP_PART"
fi

mkdir -p "$BACKUP_ROOT"
UUID="$(blkid -s UUID -o value "$BACKUP_PART")"
if ! grep -q "$UUID" /etc/fstab; then
    echo "UUID=$UUID $BACKUP_ROOT ext4 defaults 0 2" >> /etc/fstab
fi
mountpoint -q "$BACKUP_ROOT" || mount "$BACKUP_ROOT"

# B3 - répertoire de sauvegarde réservé aux administrateurs
chown root:admins "$BACKUP_ROOT"
chmod 750 "$BACKUP_ROOT"

echo "=== 12. script et planification de sauvegarde (B1/B2) ==="
install -m 750 -o root -g root "$SCRIPT_DIR/sauvegarde.sh" \
    /usr/local/sbin/sauvegarde.sh
install -m 644 -o root -g root "$CONFIG/systemd/sauvegarde.service" \
    /etc/systemd/system/sauvegarde.service
install -m 644 -o root -g root "$CONFIG/systemd/sauvegarde.timer" \
    /etc/systemd/system/sauvegarde.timer
systemctl daemon-reload
systemctl enable --now sauvegarde.timer

echo "=== 13. verifier.sh ==="
install -m 750 -o root -g root "$SCRIPT_DIR/verifier.sh" \
    /usr/local/sbin/verifier.sh

echo "installer.sh terminé."
