#!/usr/bin/env bash
# =============================================================================
# Debian kiosk eltávolítása
#
#   sudo bash uninstall.sh                  # kérdez: teljes törlés / tokenek
#   sudo bash uninstall.sh --purge          # teljes törlés (megerősítéssel)
#   sudo bash uninstall.sh --purge --yes    # teljes törlés, kérdés nélkül
#
# A --purge törli a tokeneket, az admin PIN-t, a kiosk felhasználót,
# az adatokat, az /opt/kiosk-setup forrást és a kiosk csomagokat is.
# =============================================================================
set -euo pipefail

SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export LOG_NAME="uninstall"
# shellcheck source=lib/common.sh
. "${SRC_DIR}/lib/common.sh"

[ "$(id -u)" -eq 0 ] || die "Futtasd rootként: sudo bash uninstall.sh"

KIOSK_USER="${KIOSK_USER:-kiosk}"
KIOSK_HOME="${KIOSK_HOME:-/var/lib/kiosk}"

PURGE=0
ASSUME_YES=0
DELETE_TOKENS=0
ARG_COUNT=0
KEEP_RAW="${KEEP_PACKAGES:-}"
INSTALLED_PACKAGES=()
DELETE_PACKAGES=()
KEEP_SELECTED=()

TOKEN_FILES=(
    /etc/kiosk/github.token
    /etc/kiosk/github-write.token
    /etc/kiosk/report.token
    /etc/kiosk/update.token
)

KIOSK_PACKAGES=(
    cage
    firefox-esr
    firefox-esr-l10n-hu
    libavcodec-extra
    pipewire
    pipewire-pulse
    wireplumber
    libreoffice-core
    libreoffice-writer
    libreoffice-calc
    libreoffice-impress
    tinyproxy
    wlr-randr
    openssh-server
)

usage() {
    cat <<'EOF'
Használat: sudo bash uninstall.sh [opciók]

  (nincs opció)     Kérdez: teljes törlés (--purge) és tokenek törlése
  --purge           Teljes törlés: tokenek, PIN, kiosk user, adatok,
                    /opt/kiosk-setup; a programokat táblázatban választod ki
  --keep LISTA      Megtartandó programok (vesszős lista, --purge mellett)
  --yes, -y         Megerősítés nélkül (csak --purge mellett)
  -h, --help        Ez a súgó
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --purge) PURGE=1 ;;
        --keep) KEEP_RAW="${2:-}"; shift ;;
        --yes|-y) ASSUME_YES=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "Ismeretlen opció: $1" ;;
    esac
    ARG_COUNT=$((ARG_COUNT + 1))
    shift
done

# Ha nincs kapcsoló, ajánljuk fel a teljes törlést.
if [ "$ARG_COUNT" -eq 0 ]; then
    if [ -t 0 ]; then
        printf '\nTeljes törlés (--purge)? Ez törli a tokeneket, az admin PIN-t,\n'
        printf 'a kiosk felhasználót, az adatokat és a kiosk csomagokat is.\n'
        printf 'Folytatás teljes törléssel? [i/N]: '
        read -r ans || ans=""
        case "${ans:-N}" in
            i|I|igen|IGEN|y|Y|yes|YES) PURGE=1; DELETE_TOKENS=1 ;;
        esac
    else
        echo "Nem interaktív mód: használd a --purge --yes kapcsolókat a teljes törléshez."
    fi
fi

if [ "$PURGE" = "1" ] && [ "$ASSUME_YES" != "1" ]; then
    printf '\nFIGYELEM: teljes törlés következik.\n'
    printf 'Törlődik: tokenek, admin PIN, kiosk user, adatok, /opt/kiosk-setup.\n'
    printf 'A kiosk programokat a következő táblázatban jelölheted ki.\n'
    printf 'Biztosan folytatod? [i/N]: '
    read -r ans || ans=""
    case "${ans:-N}" in
        i|I|igen|IGEN|y|Y|yes|YES) ;;
        *) echo "Megszakítva."; exit 0 ;;
    esac
fi

if [ "$PURGE" = "1" ]; then
    DELETE_TOKENS=1
elif [ "$ARG_COUNT" -eq 0 ] && [ -t 0 ]; then
    printf '\nA tokeneket is töröljem? (github, write, report) [i/N]: '
    read -r ans || ans=""
    case "${ans:-N}" in
        i|I|igen|IGEN|y|Y|yes|YES) DELETE_TOKENS=1 ;;
    esac
fi

step() { printf '\n==> %s\n' "$*"; }

package_desc() {
    case "$1" in
        cage) echo "Kiosk Wayland compositor" ;;
        firefox-esr) echo "Firefox böngésző" ;;
        firefox-esr-l10n-hu) echo "Firefox magyar nyelvi csomag" ;;
        libavcodec-extra) echo "Videó-kodekek" ;;
        pipewire) echo "Hangrendszer" ;;
        pipewire-pulse) echo "PulseAudio kompatibilitás" ;;
        wireplumber) echo "Hang-session kezelő" ;;
        libreoffice-core) echo "LibreOffice alap" ;;
        libreoffice-writer) echo "LibreOffice Writer" ;;
        libreoffice-calc) echo "LibreOffice Calc" ;;
        libreoffice-impress) echo "LibreOffice Impress" ;;
        tinyproxy) echo "Allowlist proxy" ;;
        wlr-randr) echo "Kijelzőfelbontás" ;;
        openssh-server) echo "SSH szerver" ;;
        *) echo "Kiosk program" ;;
    esac
}

table_header() {
    printf '\n%-4s %-24s %-34s %s\n' "Nr." "Program" "Leírás" "Állapot"
    printf '%-4s %-24s %-34s %s\n' "---" "------------------------" "----------------------------------" "--------"
}

table_row() {
    printf '%-4d %-24s %-34s %s\n' "$1" "$2" "$(package_desc "$2")" "$3"
}

# A telepített kiosk programok összegyűjtése.
if [ "$PURGE" = "1" ]; then
    for pkg in "${KIOSK_PACKAGES[@]}"; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
            INSTALLED_PACKAGES+=("$pkg")
        fi
    done
fi

# Táblázat: alapból minden program törlésre kerül; a felhasználó
# kiválaszthatja, melyeket tartson meg.
if [ "$PURGE" = "1" ] && [ "${#INSTALLED_PACKAGES[@]}" -gt 0 ]; then
    if [ "$ASSUME_YES" != "1" ]; then
        if [ ! -t 0 ]; then
            die "Nem interaktív mód: használd a --purge --yes --keep LISTA kapcsolókat."
        fi
        table_header
        idx=1
        for pkg in "${INSTALLED_PACKAGES[@]}"; do
            table_row "$idx" "$pkg" "törlés"
            idx=$((idx + 1))
        done
        printf '\nAlapból minden program törlésre kerül.\n'
        printf 'Mely programokat TARTSAM MEG? Add meg a sorszámokat vesszővel,\n'
        printf 'vagy írd be: mind (mindent megtart), Enter (egyiket sem).\n'
        while :; do
            read -r -p "Megtartandó sorszámok: " selection || selection=""
            case "$selection" in
                "" ) KEEP_SELECTED=(); break ;;
                mind|MIND|mindet|MINDET)
                    KEEP_SELECTED=("${INSTALLED_PACKAGES[@]}")
                    break
                    ;;
                *)
                    invalid=0
                    chosen=()
                    for token in ${selection//,/ }; do
                        if [[ "$token" =~ ^[0-9]+$ ]] && \
                           [ "$token" -ge 1 ] && [ "$token" -le "${#INSTALLED_PACKAGES[@]}" ]; then
                            chosen+=("${INSTALLED_PACKAGES[$((token - 1))]}")
                        else
                            invalid=1
                        fi
                    done
                    if [ "$invalid" = "1" ]; then
                        printf 'Érvénytelen sorszám; próbáld újra.\n'
                        continue
                    fi
                    KEEP_SELECTED=("${chosen[@]}")
                    break
                    ;;
            esac
        done
    fi

    # --keep / KEEP_PACKAGES nevek hozzáadása.
    if [ -n "$KEEP_RAW" ]; then
        for name in ${KEEP_RAW//,/ }; do
            found=0
            for pkg in "${INSTALLED_PACKAGES[@]}"; do
                if [ "$name" = "$pkg" ]; then
                    KEEP_SELECTED+=("$pkg")
                    found=1
                fi
            done
            [ "$found" = "1" ] || printf 'Figyelem: a(z) %s nem telepített kiosk program, kihagyva.\n' "$name"
        done
    fi

    # Törlendő = telepített - megtartott.
    for pkg in "${INSTALLED_PACKAGES[@]}"; do
        keep=0
        for selected in "${KEEP_SELECTED[@]:-}"; do
            if [ "$pkg" = "$selected" ]; then
                keep=1
                break
            fi
        done
        [ "$keep" = "0" ] && DELETE_PACKAGES+=("$pkg")
    done

    printf '\nVégső programtáblázat:\n'
    table_header
    idx=1
    for pkg in "${INSTALLED_PACKAGES[@]}"; do
        status="törlés"
        for selected in "${KEEP_SELECTED[@]:-}"; do
            [ "$pkg" = "$selected" ] && status="MEGTART"
        done
        table_row "$idx" "$pkg" "$status"
        idx=$((idx + 1))
    done
fi

step "Szolgáltatások leállítása"
systemctl disable --now kiosk-firstboot.service kiosk-sync.timer kiosk-docs.path \
    kiosk-proxy.service kiosk-docs.service kiosk-admin-ui.service \
    kiosk-session.service kiosk-update.timer >/dev/null 2>&1 || true
systemctl stop kiosk-sync.service kiosk-update.service >/dev/null 2>&1 || true
pkill -TERM -u "$KIOSK_USER" -x firefox-esr 2>/dev/null || true
pkill -TERM -u "$KIOSK_USER" -x cage 2>/dev/null || true

step "Autologin visszavonása"
rm -f /etc/systemd/system/getty@tty1.service.d/autologin.conf
rmdir /etc/systemd/system/getty@tty1.service.d 2>/dev/null || true
systemctl daemon-reload
systemctl restart getty@tty1.service >/dev/null 2>&1 || true

step "Belépéskori jelentés eltávolítása"
if command -v pam-auth-update >/dev/null 2>&1; then
    pam-auth-update --remove kiosk-login-report >/dev/null 2>&1 || true
fi
rm -f /usr/share/pam-configs/kiosk-login-report

step "Fájlok törlése"
rm -f /etc/systemd/system/kiosk-sync.service \
    /etc/systemd/system/kiosk-sync.timer \
    /etc/systemd/system/kiosk-proxy.service \
    /etc/systemd/system/kiosk-docs.service \
    /etc/systemd/system/kiosk-docs.path \
    /etc/systemd/system/kiosk-usb-import@.service \
    /etc/systemd/system/kiosk-admin-ui.service \
    /etc/systemd/system/kiosk-update.service \
    /etc/systemd/system/kiosk-update.timer \
    /etc/systemd/system/kiosk-firstboot.service
rm -f /usr/lib/tmpfiles.d/kiosk.conf
rm -f /etc/systemd/logind.conf.d/99-kiosk.conf
rm -f /etc/udev/rules.d/99-kiosk-usb.rules
rm -f /usr/local/bin/kiosk-session.sh /usr/local/bin/kiosk-sync.sh \
    /usr/local/bin/kiosk-render.sh /usr/local/bin/kiosk-docs.sh \
    /usr/local/bin/kiosk-usb-import.sh /usr/local/bin/kiosk-admin.sh \
    /usr/local/bin/kiosk-login-report.sh /usr/local/bin/kiosk-admin-ui.py \
    /usr/local/bin/kiosk-set-resolution.sh /usr/local/bin/kiosk-update.sh \
    /usr/local/sbin/kiosk-firstboot
rm -f /var/log/kiosk-update.log
rm -rf /usr/lib/kiosk /usr/share/kiosk
rm -f /etc/firefox-esr/policies/policies.json /etc/firefox/policies/policies.json
rm -f /etc/ssh/sshd_config.d/10-kiosk.conf

if [ "$PURGE" = "1" ]; then
    step "Teljes törlés: tokenek, adatok, felhasználó, forrás"
    rm -rf /etc/kiosk /srv/kiosk "$KIOSK_HOME" /opt/kiosk-setup
    rm -f /var/log/kiosk-firstboot.log /var/log/kiosk*.log
    if id -u "$KIOSK_USER" >/dev/null 2>&1; then
        userdel -r "$KIOSK_USER" 2>/dev/null || userdel "$KIOSK_USER" 2>/dev/null || true
    fi
    echo "    /etc/kiosk (tokenek, PIN), /srv/kiosk, ${KIOSK_HOME} és /opt/kiosk-setup törölve."
else
    if [ "$DELETE_TOKENS" = "1" ]; then
        step "Tokenek törlése"
        rm -f "${TOKEN_FILES[@]}"
        find /etc/kiosk -maxdepth 1 -type f -name '*.token' -delete 2>/dev/null || true
        echo "    GitHub/report tokenek törölve."
    else
        echo "    A tokenek megmaradtak (/etc/kiosk/*.token). Teljes törléshez: --purge"
    fi
    echo "    A /etc/kiosk, /srv/kiosk és ${KIOSK_HOME} megmaradt (--purge törli)."
fi

if [ "$PURGE" = "1" ]; then
    step "Kiosk programok eltávolítása (apt purge)"
    if [ "${#DELETE_PACKAGES[@]}" -gt 0 ]; then
        echo "    Törlésre jelölve: ${DELETE_PACKAGES[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get purge -y "${DELETE_PACKAGES[@]}" || \
            log "WARN" "Néhány csomag eltávolítása nem sikerült."
    else
        echo "    Nincs törlésre jelölt program."
    fi
    if [ "${#KEEP_SELECTED[@]}" -gt 0 ]; then
        echo "    Megtartva: ${KEEP_SELECTED[*]}"
    fi
fi

systemctl daemon-reload
systemctl reset-failed >/dev/null 2>&1 || true
udevadm control --reload-rules 2>/dev/null || true

step "Kész"
if [ "$PURGE" = "1" ]; then
    echo "    Teljes törlés megtörtént; a tokenek is törölve."
else
    echo "    A kiosk eltávolítva; a tokenek állapota: $([ "$DELETE_TOKENS" = "1" ] && echo törölve || echo megmaradt)."
fi
