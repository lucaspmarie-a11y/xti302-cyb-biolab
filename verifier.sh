#!/bin/bash
# verifier.sh - vérifie automatiquement chaque exigence du cahier des
# charges (contexte C - BioLab). N'affecte jamais l'état du système, sauf
# fichiers de test temporaires, supprimés à la fin.
#
# set -e est volontairement absent : ce script enchaîne des commandes
# dont l'échec est un résultat normal (ex: sudo -u X test -r Y qui échoue
# parce que X n'a pas le droit), pas une erreur fatale du script lui-même.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CSV="${CSV:-$SCRIPT_DIR/comptes.csv}"
[ -f "$CSV" ] || CSV="/opt/xti302-biolab/comptes.csv"
DOSSIER="$SCRIPT_DIR/DOSSIER.md"
[ -f "$DOSSIER" ] || DOSSIER="/opt/xti302-biolab/DOSSIER.md"

PASS=0
FAIL=0
TMPFILES=()

ok() { echo "[OK] $1 $2"; PASS=$((PASS+1)); }
ko() { echo "[KO] $1 $2"; FAIL=$((FAIL+1)); }

cleanup() {
    for f in "${TMPFILES[@]}"; do rm -f "$f" 2>/dev/null; done
}
trap cleanup EXIT

# ---------- C1 : comptes et groupes conformes à comptes.csv ----------
test_C1() {
    local bad=0
    while IFS=';' read -r login nom gp gs; do
        [ -z "$login" ] && continue
        if ! id "$login" >/dev/null 2>&1; then
            ko "C1" "le compte $login n'existe pas"
            bad=1
            continue
        fi
        actual_gp="$(id -gn "$login")"
        if [ "$actual_gp" != "$gp" ]; then
            ko "C1" "$login : groupe principal $actual_gp attendu $gp"
            bad=1
        fi
        IFS=',' read -ra secs <<< "$gs"
        for s in "${secs[@]}"; do
            [ -z "$s" ] && continue
            if ! id -nG "$login" | tr ' ' '\n' | grep -qx "$s"; then
                ko "C1" "$login n'est pas membre de $s"
                bad=1
            fi
        done
    done < <(tail -n +2 "$CSV")
    [ "$bad" -eq 0 ] && ok "C1" "tous les comptes de comptes.csv existent avec les bons groupes"
}

# ---------- C2 : droits et ACL sur /srv ----------
test_C2_donnees_brutes() {
    local d=/srv/donnees_brutes
    sudo -u jrousseau test -w "$d" && sudo -u cfabre test -w "$d" \
        && sudo -u amorel test -r "$d" && ! sudo -u slevy test -w "$d" \
        && sudo -u tgauthier test -r "$d" && ! sudo -u eblanc test -r "$d" \
        && ok "C2" "$d : technique rw, chercheurs/doctorants r, invite aucun accès" \
        || ko "C2" "$d : droits non conformes"
}

test_C2_analyses() {
    local d=/srv/analyses
    sudo -u amorel test -w "$d" && sudo -u tgauthier test -w "$d" \
        && ! sudo -u jrousseau test -r "$d" \
        && ok "C2" "$d : chercheurs/doctorants rw, technique aucun accès" \
        || ko "C2" "$d : droits non conformes"
}

test_C2_publications() {
    local d=/srv/publications
    sudo -u amorel test -w "$d" && sudo -u tgauthier test -r "$d" \
        && ! sudo -u tgauthier test -w "$d" && sudo -u pleroy test -r "$d" \
        && ok "C2" "$d : chercheurs rw, doctorants/invite r" \
        || ko "C2" "$d : droits non conformes"
}

test_C2_acl_defaut() {
    local d=/srv/analyses
    local tmp="$d/.verif_acl_test"
    if sudo -u amorel touch "$tmp" 2>/dev/null; then
        TMPFILES+=("$tmp")
        if sudo -u tgauthier test -w "$tmp"; then
            ok "C2" "ACL par défaut appliquées aux nouveaux fichiers de $d"
        else
            ko "C2" "les fichiers créés dans $d n'héritent pas des ACL par défaut"
        fi
    else
        ko "C2" "impossible de créer un fichier de test dans $d"
    fi
}

# ---------- C3 : sudo ----------
test_C3_admins() {
    sudo -l -U lmarie 2>/dev/null | grep -q "(ALL : ALL) ALL" \
        && ok "C3" "lmarie (admins) a tous les droits sudo" \
        || ko "C3" "lmarie n'a pas les droits sudo attendus"
}

test_C3_support() {
    local out
    out="$(sudo -l -U support 2>/dev/null)"
    echo "$out" | grep -q "analyse_logs.sh" && ! echo "$out" | grep -q "(ALL : ALL) ALL" \
        && ok "C3" "support ne peut lancer que analyse_logs.sh en sudo" \
        || ko "C3" "support a des droits sudo non conformes"
}

# ---------- C4 : root verrouillé, home privés ----------
test_C4_root_locked() {
    passwd -S root 2>/dev/null | grep -qE '^root (L|LK)' \
        && ok "C4" "le compte root est verrouillé" \
        || ko "C4" "le compte root n'est pas verrouillé"
}

test_C4_home_prive() {
    local bad=0
    for h in /home/*; do
        [ -d "$h" ] || continue
        perm="$(stat -c '%a' "$h")"
        case "$perm" in
            7[0-5]0|7[0-5][0-5]) : ;;
            *) bad=1 ;;
        esac
    done
    [ "$bad" -eq 0 ] && ok "C4" "les répertoires personnels ne sont pas lisibles par les autres" \
        || ko "C4" "au moins un répertoire personnel est lisible par les autres"
}

# ---------- S1-S5 : SSH ----------
test_S1() {
    sshd -T 2>/dev/null | grep -qi '^passwordauthentication no$' \
        && ok "S1" "authentification par mot de passe refusée" \
        || ko "S1" "PasswordAuthentication n'est pas à 'no'"
}

test_S2() {
    sshd -T 2>/dev/null | grep -qi '^permitrootlogin no$' \
        && ok "S2" "connexion root refusée" \
        || ko "S2" "PermitRootLogin n'est pas à 'no'"
}

test_S3() {
    sshd -T 2>/dev/null | grep -qi '^allowgroups.*acces_ssh' \
        && ok "S3" "seul le groupe acces_ssh peut se connecter en SSH" \
        || ko "S3" "AllowGroups acces_ssh absent de la configuration effective"
}

test_S4_maxauthtries() {
    sshd -T 2>/dev/null | grep -qi '^maxauthtries 4$' \
        && ok "S4" "au plus 4 tentatives d'authentification" \
        || ko "S4" "MaxAuthTries n'est pas à 4"
}

test_S4_timeout() {
    local interval count
    interval=$(sshd -T 2>/dev/null | awk '/^clientaliveinterval/{print $2}')
    count=$(sshd -T 2>/dev/null | awk '/^clientalivecountmax/{print $2}')
    if [ -n "$interval" ] && [ -n "$count" ] && [ $((interval*count)) -le 900 ] && [ $((interval*count)) -gt 0 ]; then
        ok "S4" "session inactive fermée en 15 minutes au plus"
    else
        ko "S4" "délai d'inactivité SSH non conforme"
    fi
}

test_S5() {
    [ -f /etc/ssh/sshd_config.d/10-hardening.conf ] && sshd -t 2>/dev/null \
        && ok "S5" "configuration dans sshd_config.d/ et validée par sshd -t" \
        || ko "S5" "configuration absente de sshd_config.d/ ou invalide"
}

# ---------- J1-J4 : journaux et défense ----------
test_J1_actif() {
    systemctl is-active --quiet fail2ban \
        && ok "J1" "fail2ban est actif" \
        || ko "J1" "fail2ban n'est pas actif"
}

test_J1_jail() {
    fail2ban-client status sshd >/dev/null 2>&1 \
        && ok "J1" "la jail sshd de fail2ban est chargée" \
        || ko "J1" "la jail sshd de fail2ban n'est pas chargée"
}

test_J2_policy() {
    nft list ruleset 2>/dev/null | grep -A2 'chain input' | grep -q 'policy drop' \
        && ok "J2" "politique par défaut du pare-feu : drop" \
        || ko "J2" "politique par défaut du pare-feu non conforme (attendu : drop)"
}

test_J2_ssh_autorise() {
    nft list ruleset 2>/dev/null | grep -q 'tcp dport 22 accept' \
        && ok "J2" "le port SSH (22) est autorisé en entrée" \
        || ko "J2" "le port SSH n'est pas explicitement autorisé"
}

test_J3() {
    grep -qi '^Storage=persistent' /etc/systemd/journald.conf.d/*.conf 2>/dev/null \
        && [ -d /var/log/journal ] \
        && ok "J3" "le journal systemd est persistant" \
        || ko "J3" "le journal systemd n'est pas configuré en mode persistant"
}

test_J4() {
    [ -x /usr/local/sbin/analyse_logs.sh ] \
        && /usr/local/sbin/analyse_logs.sh >/dev/null 2>&1; rc=$?
    if [ -x /usr/local/sbin/analyse_logs.sh ] && [ "$rc" -le 1 ]; then
        ok "J4" "analyse_logs.sh s'exécute et renvoie un code de sortie exploitable"
    else
        ko "J4" "analyse_logs.sh absent, non exécutable, ou code de sortie inattendu"
    fi
}

# ---------- B1-B4 : sauvegarde ----------
test_B1_script() {
    [ -x /usr/local/sbin/sauvegarde.sh ] \
        && grep -q -- '--link-dest' /usr/local/sbin/sauvegarde.sh \
        && ok "B1" "sauvegarde.sh existe et fait une sauvegarde incrémentale (--link-dest)" \
        || ko "B1" "sauvegarde.sh absent ou non incrémental"
}

test_B1_versions() {
    local n
    n=$(ls -1 /mnt/sauvegarde/versions 2>/dev/null | wc -l)
    [ "$n" -ge 1 ] \
        && ok "B1" "au moins une version datée de sauvegarde existe ($n)" \
        || ko "B1" "aucune version de sauvegarde trouvée dans /mnt/sauvegarde/versions"
}

test_B2() {
    systemctl is-enabled --quiet sauvegarde.timer 2>/dev/null \
        && ok "B2" "la sauvegarde est planifiée (sauvegarde.timer activé)" \
        || ko "B2" "sauvegarde.timer n'est pas activé"
}

test_B3() {
    local perm owner
    perm="$(stat -c '%a' /mnt/sauvegarde 2>/dev/null)"
    owner="$(stat -c '%G' /mnt/sauvegarde 2>/dev/null)"
    [ "$owner" = "admins" ] && [ "${perm: -1}" = "0" ] \
        && ok "B3" "/mnt/sauvegarde n'est accessible qu'aux administrateurs" \
        || ko "B3" "/mnt/sauvegarde est accessible à d'autres que admins"
}

test_B4() {
    grep -qi "restaur" "$DOSSIER" 2>/dev/null \
        && ok "B4" "la procédure de restauration est documentée dans DOSSIER.md" \
        || ko "B4" "aucune procédure de restauration documentée"
}

# ---------- D1-D3 : système ----------
test_D1() {
    systemctl is-enabled --quiet unattended-upgrades 2>/dev/null \
        && ok "D1" "unattended-upgrades est actif" \
        || ko "D1" "unattended-upgrades n'est pas activé"
}

test_D2() {
    local extra
    extra="$(ss -tulpn 2>/dev/null | grep LISTEN | grep -v ':22 ' | grep -v 'sshd')"
    if [ -z "$extra" ]; then
        ok "D2" "aucun service en écoute en dehors de SSH"
    else
        ko "D2" "des services écoutent en dehors de SSH : $(echo "$extra" | tr '\n' ';')"
    fi
}

test_D3_world_writable() {
    local n
    n=$(find / -xdev \( -path /proc -o -path /sys -o -path /tmp -o -path /var/tmp \) -prune -o \
        -type f -perm -0002 ! -type l -print 2>/dev/null | wc -l)
    [ "$n" -eq 0 ] \
        && ok "D3" "aucun fichier modifiable par tous en dehors des répertoires temporaires" \
        || ko "D3" "$n fichier(s) modifiables par tous trouvés hors répertoires temporaires"
}

test_D3_suid() {
    grep -qi "suid" "$DOSSIER" 2>/dev/null \
        && ok "D3" "les fichiers SUID sont listés et expliqués dans DOSSIER.md" \
        || ko "D3" "aucune liste des fichiers SUID dans DOSSIER.md"
}

for t in test_C1 test_C2_donnees_brutes test_C2_analyses test_C2_publications \
         test_C2_acl_defaut test_C3_admins test_C3_support test_C4_root_locked \
         test_C4_home_prive test_S1 test_S2 test_S3 test_S4_maxauthtries \
         test_S4_timeout test_S5 test_J1_actif test_J1_jail test_J2_policy \
         test_J2_ssh_autorise test_J3 test_J4 test_B1_script test_B1_versions \
         test_B2 test_B3 test_B4 test_D1 test_D2 test_D3_world_writable test_D3_suid; do
    "$t"
done

echo "--- $PASS / $((PASS+FAIL)) tests réussis"
[ "$FAIL" -eq 0 ]
