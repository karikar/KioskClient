#!/usr/bin/env bash
# =============================================================================
# Debian kiosk telepítő
#
#   sudo bash install.sh
#
# Xorg nélküli, Wayland (cage) alapú kiosk: csak Firefox ESR fut, a
# könyvjelzők és a kezdőlap a privát GitHub allowlistból generálódnak.
# =============================================================================
set -euo pipefail

SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export LOG_NAME="install"
# A telepített verzió mindig a forrás VERSION fájlja.
KIOSK_VERSION="$(tr -d '[:space:]' <"${SRC_DIR}/VERSION" 2>/dev/null || true)"
: "${KIOSK_VERSION:=1.0.0}"
export KIOSK_VERSION
# shellcheck source=lib/common.sh
. "${SRC_DIR}/lib/common.sh"

# Frissítő mód (kiosk-update.sh hívja): nincs kérdés, a meglévő beállítások,
# tokenek és PIN megmaradnak.
KIOSK_UPGRADE="${KIOSK_UPGRADE:-0}"
[ "$KIOSK_UPGRADE" = "1" ] && KIOSK_UNATTENDED=1

# Újratelepítésnél/frissítésnél a meglévő kiosk.conf értékei az
# alapértelmezések; a környezeti változók továbbra is felülírják őket.
if [ -r /etc/kiosk/kiosk.conf ]; then
    while IFS= read -r _conf_line || [ -n "$_conf_line" ]; do
        case "$_conf_line" in
            [A-Z]*=*)
                _conf_name="${_conf_line%%=*}"
                case "$_conf_name" in *[!A-Z0-9_]*) continue ;; esac
                if [ -z "${!_conf_name+x}" ]; then
                    eval "$_conf_line" 2>/dev/null || true
                fi
                ;;
        esac
    done </etc/kiosk/kiosk.conf
    unset _conf_line _conf_name
fi

step() { printf '\n==> %s\n' "$*"; }
say() { printf '    %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "Futtasd rootként: sudo bash install.sh"
command -v systemctl >/dev/null 2>&1 || die "Ez a telepítő systemd-t igényel."

# shellcheck disable=SC1091
. /etc/os-release 2>/dev/null || true
if [ "${ID:-}" != "debian" ]; then
    log "WARN" "A telepítő Debian 12+ rendszerre készült (észlelt: ${PRETTY_NAME:-ismeretlen})."
fi

# --- paraméterek ------------------------------------------------------------
KIOSK_USER="${KIOSK_USER:-kiosk}"
KIOSK_HOME="${KIOSK_HOME:-/var/lib/kiosk}"
SITE_NAME="${SITE_NAME:-Kiosk}"
GITHUB_OWNER="${GITHUB_OWNER:-karikar}"
GITHUB_REPO="${GITHUB_REPO:-kiosk}"
GITHUB_REF="${GITHUB_REF:-main}"
GITHUB_PATH="${GITHUB_PATH:-allowlist.json}"
PROXY_PORT="${PROXY_PORT:-8877}"
PROXY_BYPASS_MINUTES="${PROXY_BYPASS_MINUTES:-15}"
ENFORCE_ALLOWLIST="${ENFORCE_ALLOWLIST:-1}"
REFRESH_MINUTES="${REFRESH_MINUTES:-10}"
USB_IMPORT="${USB_IMPORT:-1}"
# manual = az admin felületen kell kiválasztani, mi kerüljön be; auto = minden
USB_IMPORT_MODE="${USB_IMPORT_MODE:-manual}"
TOKEN="${GITHUB_TOKEN:-}"
WRITE_TOKEN="${GITHUB_WRITE_TOKEN:-}"

# Magyar nyelv és billentyűzet (felülírható környezeti változóval).
KIOSK_LANG="${KIOSK_LANG:-hu_HU.UTF-8}"
KEYBOARD_LAYOUT="${KEYBOARD_LAYOUT:-hu}"
KEYBOARD_MODEL="${KEYBOARD_MODEL:-pc105}"
KEYBOARD_VARIANT="${KEYBOARD_VARIANT:-}"
KEYBOARD_OPTIONS="${KEYBOARD_OPTIONS:-}"
KIOSK_UNATTENDED="${KIOSK_UNATTENDED:-0}"

# Belépéskori jelentés: ha nincs megadva, interaktívan kérdezzük meg.
REPORT_ENABLED="${REPORT_ENABLED:-}"
REPORT_TOKEN="${REPORT_TOKEN:-}"
# A célrepó alapból az allowlist repója; a kérdések után töltjük ki.
REPORT_GITHUB_OWNER="${REPORT_GITHUB_OWNER:-}"
REPORT_GITHUB_REPO="${REPORT_GITHUB_REPO:-}"
REPORT_GITHUB_REF="${REPORT_GITHUB_REF:-}"
REPORT_PATH="${REPORT_PATH:-login-logs}"

# Admin felület (GitHub allowlist szerkesztő) PIN-nel.
ADMIN_PIN="${ADMIN_PIN:-}"
ADMIN_UI_PORT="${ADMIN_UI_PORT:-8878}"

# Program önfrissítés GitHub Release-ből (kiosk-update.timer).
UPDATE_ENABLED="${UPDATE_ENABLED:-1}"
UPDATE_GITHUB_OWNER="${UPDATE_GITHUB_OWNER:-}"
UPDATE_GITHUB_REPO="${UPDATE_GITHUB_REPO:-KioskClient}"
UPDATE_INTERVAL_MINUTES="${UPDATE_INTERVAL_MINUTES:-60}"
UPDATE_WINDOW="${UPDATE_WINDOW:-}"
UPDATE_REQUIRE_CHECKSUM="${UPDATE_REQUIRE_CHECKSUM:-1}"
UPDATE_SETUP_DIR="${UPDATE_SETUP_DIR:-/opt/kiosk-setup}"
UPDATE_TOKEN="${UPDATE_TOKEN:-}"

step "Telepítési adatok"
ask() {
    local prompt="$1" default="$2" out
    read -r -p "  ${prompt} [${default}]: " out || out=""
    printf '%s' "${out:-$default}"
}
if [ -t 0 ] && [ "$KIOSK_UNATTENDED" != "1" ]; then
    GITHUB_OWNER="$(ask "GitHub tulajdonos" "$GITHUB_OWNER")"
    GITHUB_REPO="$(ask "GitHub repó" "$GITHUB_REPO")"
    GITHUB_REF="$(ask "Branch" "$GITHUB_REF")"
    GITHUB_PATH="$(ask "Allowlist fájl a repóban" "$GITHUB_PATH")"
    SITE_NAME="$(ask "Megjelenő név a kezdőlapon" "$SITE_NAME")"
    read -r -p "  Allowlist proxy bekapcsolva? [I/n]: " ans || ans=""
    case "${ans:-I}" in
        n | N | no | nem | NO | NEM) ENFORCE_ALLOWLIST=0 ;;
        *) ENFORCE_ALLOWLIST=1 ;;
    esac
    if [ -z "$REPORT_ENABLED" ]; then
        read -r -p "  Belépéskori jelentés GitHubra (IP + időpont + napló)? [i/N]: " ans || ans=""
        case "${ans:-N}" in
            i | I | y | Y | igen | IGEN | yes | YES) REPORT_ENABLED=1 ;;
            *) REPORT_ENABLED=0 ;;
        esac
    fi
    if [ -z "$ADMIN_PIN" ]; then
        if [ -s /etc/kiosk/admin.pin ]; then
            read -r -p "  Új admin PIN (4-8 számjegy, Enter = a meglévő marad): " ADMIN_PIN || ADMIN_PIN=""
        else
            read -r -p "  Admin PIN az admin felülethez (4-8 számjegy, üres = kikapcsolva): " ADMIN_PIN || ADMIN_PIN=""
        fi
    fi
    _upd_default="${UPDATE_GITHUB_OWNER:-$GITHUB_OWNER}/${UPDATE_GITHUB_REPO}"
    [ "$UPDATE_ENABLED" = "1" ] || _upd_default="-"
    _upd="$(ask "Programfrissítés GitHub repója (tulajdonos/repó, '-' = kikapcsolva)" "$_upd_default")"
    case "$_upd" in
        - | "") UPDATE_ENABLED=0 ;;
        */*)
            UPDATE_ENABLED=1
            UPDATE_GITHUB_OWNER="${_upd%%/*}"
            UPDATE_GITHUB_REPO="${_upd#*/}"
            ;;
        *) log "WARN" "Érvénytelen repó ('${_upd}') - az alapértelmezést használom." ;;
    esac
    unset _upd _upd_default
fi

# A programfrissítés repója alapból az allowlist tulajdonosáé.
: "${UPDATE_GITHUB_OWNER:=$GITHUB_OWNER}"

# A jelentés célrepója alapból ugyanaz, mint az allowlisté (felülírható).
: "${REPORT_GITHUB_OWNER:=$GITHUB_OWNER}"
: "${REPORT_GITHUB_REPO:=$GITHUB_REPO}"
: "${REPORT_GITHUB_REF:=$GITHUB_REF}"

if [ -z "$TOKEN" ] && [ ! -s /etc/kiosk/github.token ]; then
    if [ -t 0 ] && [ "$KIOSK_UNATTENDED" != "1" ]; then
        printf '  GitHub token (fine-grained, Contents: Read) - a bevitel nem látszik.\n'
        read -r -s -p "  Token: " TOKEN || TOKEN=""
        printf '\n'
    fi
fi

if [ -z "$TOKEN" ] && [ ! -s /etc/kiosk/github.token ]; then
    die "Nincs GitHub token. Add meg GITHUB_TOKEN=... környezeti változóként, vagy futtasd interaktívan."
fi

# Belépéskori jelentés: ha nincs explicit beállítás, a meglévő report token
# vagy a REPORT_TOKEN környezeti változó dönt; különben kikapcsolva marad.
if [ -z "$REPORT_ENABLED" ]; then
    if [ -n "$REPORT_TOKEN" ] || [ -s /etc/kiosk/report.token ]; then
        REPORT_ENABLED=1
    else
        REPORT_ENABLED=0
    fi
fi

if [ "$REPORT_ENABLED" = "1" ] && [ -z "$REPORT_TOKEN" ] && [ ! -s /etc/kiosk/report.token ]; then
    if [ -t 0 ]; then
        printf '  GitHub token a belépéskori jelentéshez (Contents: Read and write) - a bevitel nem látszik.\n'
        read -r -s -p "  Report token: " REPORT_TOKEN || REPORT_TOKEN=""
        printf '\n'
    fi
fi

if [ "$REPORT_ENABLED" = "1" ] && [ -z "$REPORT_TOKEN" ] && [ ! -s /etc/kiosk/report.token ]; then
    log "WARN" "Nincs report token - a belépéskori jelentés kikapcsolva."
    REPORT_ENABLED=0
fi

# Az admin felület GitHubra íráshoz külön, Contents: Read and write tokent használ.
# Nem kötelező: ha nincs, a felület csak olvasni tud.
if [ -n "$ADMIN_PIN" ] && [ -z "$WRITE_TOKEN" ] && [ ! -s /etc/kiosk/github-write.token ] && [ -t 0 ] && [ "$KIOSK_UNATTENDED" != "1" ]; then
    printf '  GitHub write token az admin szerkesztéshez (Contents: Read and write, Enter = kihagy).\n'
    read -r -s -p "  Write token: " WRITE_TOKEN || WRITE_TOKEN=""
    printf '\n'
fi

# Admin PIN: ha üres és nincs meglévő PIN, a helyi engedélyező felület nem indul el.
if [ -n "$ADMIN_PIN" ] && ! pin_valid_format "$ADMIN_PIN"; then
    log "WARN" "Az admin PIN formátuma hibás (4-8 számjegy) - a PIN nem változik."
    ADMIN_PIN=""
fi
ADMIN_ENABLED=0
if [ -n "$ADMIN_PIN" ] || [ -s /etc/kiosk/admin.pin ]; then
    ADMIN_ENABLED=1
fi

say "Verzió: ${KIOSK_VERSION}$([ "$KIOSK_UPGRADE" = 1 ] && echo " (frissítés)")"
say "Repó:   ${GITHUB_OWNER}/${GITHUB_REPO}/${GITHUB_PATH}@${GITHUB_REF}"
say "Név:    ${SITE_NAME}"
say "Proxy:  $([ "$ENFORCE_ALLOWLIST" = 1 ] && echo "bekapcsolva (127.0.0.1:${PROXY_PORT})" || echo "kikapcsolva")"
say "Jelentés: $([ "$REPORT_ENABLED" = 1 ] && echo "bekapcsolva (${REPORT_GITHUB_OWNER}/${REPORT_GITHUB_REPO}/${REPORT_PATH})" || echo "kikapcsolva")"
say "Admin PIN: $([ "$ADMIN_ENABLED" = 1 ] && echo "beállítva (127.0.0.1:${ADMIN_UI_PORT})" || echo "nincs - helyi engedélyező felület kikapcsolva")"
say "Frissítés: $([ "$UPDATE_ENABLED" = 1 ] && echo "${UPDATE_GITHUB_OWNER}/${UPDATE_GITHUB_REPO} releases, ${UPDATE_INTERVAL_MINUTES} percenként" || echo "kikapcsolva")"

# --- csomagok ---------------------------------------------------------------
step "Csomagok telepítése (cage, Firefox ESR, LibreOffice, tinyproxy)"
export DEBIAN_FRONTEND=noninteractive
KIOSK_PACKAGES=(
    cage
    firefox-esr firefox-esr-l10n-hu
    libavcodec-extra
    pipewire pipewire-pulse wireplumber
    libreoffice-core libreoffice-writer libreoffice-calc libreoffice-impress
    fonts-liberation fonts-dejavu-core fonts-noto-color-emoji
    curl ca-certificates jq locales python3 xkb-data wlr-randr util-linux
    openssh-server
    mc
    tinyproxy
)
if [ "$KIOSK_UPGRADE" = "1" ]; then
    # Frissítéskor az apt hibája (pl. tükörszerver kiesés) csak akkor végzetes,
    # ha az új verzióhoz tényleg hiányzik csomag.
    if ! { apt-get update -qq && apt-get install -y --no-install-recommends "${KIOSK_PACKAGES[@]}"; }; then
        missing=()
        for p in "${KIOSK_PACKAGES[@]}"; do
            dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p")
        done
        [ "${#missing[@]}" -eq 0 ] || die "Az apt nem futott le, és hiányzó csomagok vannak: ${missing[*]}"
        log "WARN" "Az apt nem futott le, de minden szükséges csomag telepítve van - folytatom."
    fi
else
    apt-get update -qq
    apt-get install -y --no-install-recommends "${KIOSK_PACKAGES[@]}"
fi

command -v firefox-esr >/dev/null 2>&1 || die "A firefox-esr nem települt."
command -v cage >/dev/null 2>&1 || die "A cage nem települt."
command -v jq >/dev/null 2>&1 || die "A jq nem települt."

# --- OpenSSH szerver --------------------------------------------------------
# A telepítő alapból telepíti; a bejelentkezés a megadott admin
# felhasználóval, jelszóval történik. Root belépés tiltva.
step "OpenSSH szerver beállítása"
if [ -x /usr/sbin/sshd ]; then
    install -d -m 0755 /etc/ssh/sshd_config.d
    cat >/etc/ssh/sshd_config.d/10-kiosk.conf <<'EOF'
# Debian kiosk - SSH alapbeállítások
PermitRootLogin no
PasswordAuthentication yes
KbdInteractiveAuthentication no
UsePAM yes
X11Forwarding no
AllowAgentForwarding no
EOF
    chmod 0644 /etc/ssh/sshd_config.d/10-kiosk.conf
    systemctl enable ssh >/dev/null 2>&1 || true
    systemctl restart ssh >/dev/null 2>&1 || \
        log "WARN" "Az SSH szerver nem indult el."
    say "SSH: engedélyezve (22/tcp, jelszavas belépés, root tiltva)"
else
    log "WARN" "Az openssh-server nem települt; SSH nem elérhető."
fi

TINYPROXY_BIN="$(command -v tinyproxy || true)"
[ -n "$TINYPROXY_BIN" ] || die "A tinyproxy nem települt."

# A Debian firefox-esr AppArmor profilja alapból csak a home alatti profilra
# ad jogot. A kiosk profil a /var/lib/kiosk alatt van, ezért helyi kivétel.
if [ -d /etc/apparmor.d ] && command -v apparmor_parser >/dev/null 2>&1; then
    install -d -m 0755 /etc/apparmor.d/local
    cat >/etc/apparmor.d/local/firefox-esr <<'EOF'
# Debian kiosk: a böngésző profilja a /var/lib/kiosk alatt él.
/var/lib/kiosk/** rwk,
/srv/kiosk/** r,
EOF
    if [ -f /etc/apparmor.d/firefox-esr ]; then
        apparmor_parser -r /etc/apparmor.d/firefox-esr >/dev/null 2>&1 || \
            log "WARN" "Az AppArmor profil újratöltése nem sikerült (nem végzetes)."
    fi
fi

# A disztribúciós tinyproxy service ne kaparja el a portot.
systemctl disable --now tinyproxy.service >/dev/null 2>&1 || true

say "firefox-esr: $(firefox-esr --version 2>/dev/null | head -1 || echo ismeretlen)"

# Magyar nyelv a Firefoxhoz (a felület és a hibaoldalak is magyarul).
if [ -f /etc/locale.gen ]; then
    sed -i 's/^# *hu_HU.UTF-8 UTF-8/hu_HU.UTF-8 UTF-8/' /etc/locale.gen
    grep -q '^hu_HU.UTF-8 UTF-8' /etc/locale.gen || echo 'hu_HU.UTF-8 UTF-8' >>/etc/locale.gen
    locale-gen >/dev/null 2>&1 || log "WARN" "A hu_HU.UTF-8 locale generálása nem sikerült."
fi

# Billentyűzet: konzolra (/etc/default/keyboard) és Waylandre (XKB_DEFAULT_*).
step "Billentyűzet beállítása (${KEYBOARD_LAYOUT})"
if [ -d /etc/default ]; then
    cat >/etc/default/keyboard <<EOF
XKBMODEL="${KEYBOARD_MODEL}"
XKBLAYOUT="${KEYBOARD_LAYOUT}"
XKBVARIANT="${KEYBOARD_VARIANT}"
XKBOPTIONS="${KEYBOARD_OPTIONS}"
BACKSPACE="guess"
EOF
    chmod 0644 /etc/default/keyboard
    if command -v setupcon >/dev/null 2>&1; then
        setupcon >/dev/null 2>&1 || \
            log "WARN" "A konzol billentyűzet beállítása nem sikerült (nem végzetes)."
    fi
    say "Konzol: ${KEYBOARD_LAYOUT} / ${KEYBOARD_MODEL}"
else
    log "WARN" "A /etc/default/keyboard nem hozható létre."
fi

# --- felhasználó és könyvtárak ---------------------------------------------
step "Kiosk felhasználó és könyvtárak"
if ! id -u "$KIOSK_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "$KIOSK_HOME" \
        --shell /bin/bash --comment "Kiosk" "$KIOSK_USER"
    say "Létrehozva: ${KIOSK_USER}"
else
    say "Már létezik: ${KIOSK_USER}"
    cur_home="$(getent passwd "$KIOSK_USER" | cut -d: -f6)"
    if [ "$cur_home" != "$KIOSK_HOME" ]; then
        log "WARN" "A ${KIOSK_USER} home könyvtára ${cur_home}, a kiosk viszont ${KIOSK_HOME}-t használ."
    fi
fi
passwd -l "$KIOSK_USER" >/dev/null 2>&1 || true
for grp in video render input audio; do
    if getent group "$grp" >/dev/null 2>&1; then
        usermod -aG "$grp" "$KIOSK_USER" 2>/dev/null || true
    fi
done

install -d -m 0755 /etc/kiosk /usr/lib/kiosk /usr/local/bin
install -d -m 0755 /usr/share/kiosk/firefox /usr/share/kiosk/web /usr/share/kiosk/proxy
install -d -m 0755 "$KIOSK_HOME" "$KIOSK_HOME/state" "$KIOSK_HOME/Downloads" "$KIOSK_HOME/.cache"
install -d -m 0755 /srv/kiosk /srv/kiosk/docs /srv/kiosk/inbox /srv/kiosk/inbox/processed
install -d -m 0755 /etc/firefox-esr/policies /etc/firefox/policies
install -d -m 0755 /etc/systemd/logind.conf.d /etc/systemd/system/getty@tty1.service.d
chown -R "${KIOSK_USER}:${KIOSK_USER}" "$KIOSK_HOME" /srv/kiosk
chmod 700 "$KIOSK_HOME"

# --- fájlok ----------------------------------------------------------------
step "Programfájlok telepítése"
install -m 0644 "${SRC_DIR}/lib/common.sh" /usr/lib/kiosk/common.sh
install -m 0644 "${SRC_DIR}/lib/render.sh" /usr/lib/kiosk/render.sh
install -m 0644 "${SRC_DIR}/lib/allowlist.jq" /usr/lib/kiosk/allowlist.jq
install -m 0644 "${SRC_DIR}/lib/policies.jq" /usr/lib/kiosk/policies.jq

for f in kiosk-session.sh kiosk-set-resolution.sh kiosk-sync.sh kiosk-render.sh kiosk-docs.sh \
    kiosk-usb-import.sh kiosk-admin.sh kiosk-login-report.sh kiosk-update.sh; do
    install -m 0755 "${SRC_DIR}/bin/${f}" "/usr/local/bin/${f}"
done
install -m 0755 "${SRC_DIR}/bin/kiosk-admin-ui.py" /usr/local/bin/kiosk-admin-ui.py

install -m 0644 "${SRC_DIR}/firefox/user.js" /usr/share/kiosk/firefox/user.js
install -m 0644 "${SRC_DIR}/firefox/userChrome.css" /usr/share/kiosk/firefox/userChrome.css
install -m 0644 "${SRC_DIR}/web/style.css" /usr/share/kiosk/web/style.css
install -m 0644 "${SRC_DIR}/web/clock.js" /usr/share/kiosk/web/clock.js
install -m 0644 "${SRC_DIR}/web/theme.js" /usr/share/kiosk/web/theme.js
install -m 0644 "${SRC_DIR}/web/admin.html" /usr/share/kiosk/web/admin.html
install -m 0644 "${SRC_DIR}/web/unlock.html" /usr/share/kiosk/web/unlock.html
install -m 0644 "${SRC_DIR}/proxy/tinyproxy.conf.in" /usr/share/kiosk/proxy/tinyproxy.conf.in
install -m 0644 "${SRC_DIR}/proxy/error.html" /usr/share/kiosk/proxy/error.html
install -d -m 0755 /usr/share/doc/debian-kiosk
install -m 0644 "${SRC_DIR}/README.md" /usr/share/doc/debian-kiosk/README.md

# --- konfiguráció -----------------------------------------------------------
step "Konfiguráció"
{
    printf '# Debian kiosk konfiguráció - %s\n' "$(date '+%F %T')"
    printf '# Újragenerálás: kiosk-admin.sh render\n\n'
    printf 'KIOSK_USER=%q\n' "$KIOSK_USER"
    printf 'KIOSK_HOME=%q\n' "$KIOSK_HOME"
    printf 'KIOSK_ETC=%q\n' "/etc/kiosk"
    printf 'SITE_NAME=%q\n' "$SITE_NAME"
    printf '\n'
    printf 'GITHUB_OWNER=%q\n' "$GITHUB_OWNER"
    printf 'GITHUB_REPO=%q\n' "$GITHUB_REPO"
    printf 'GITHUB_REF=%q\n' "$GITHUB_REF"
    printf 'GITHUB_PATH=%q\n' "$GITHUB_PATH"
    printf 'GITHUB_TOKEN_FILE=%q\n' "/etc/kiosk/github.token"
    printf 'GITHUB_WRITE_TOKEN_FILE=%q\n' "/etc/kiosk/github-write.token"
    printf '\n'
    printf 'ENFORCE_ALLOWLIST=%q\n' "$ENFORCE_ALLOWLIST"
    printf 'PROXY_PORT=%q\n' "$PROXY_PORT"
    printf 'PROXY_BYPASS_MINUTES=%q\n' "$PROXY_BYPASS_MINUTES"
    printf 'REFRESH_MINUTES=%q\n' "$REFRESH_MINUTES"
    printf 'USB_IMPORT=%q\n' "$USB_IMPORT"
    printf 'USB_IMPORT_MODE=%q\n' "$USB_IMPORT_MODE"
    printf 'MAX_FILE_MB=%q\n' "2048"
    printf 'USB_MOUNT_ROOT=%q\n' "/run/media/kiosk-usb"
    printf 'KIOSK_LANG=%q\n' "$KIOSK_LANG"
    printf 'KEYBOARD_LAYOUT=%q\n' "$KEYBOARD_LAYOUT"
    printf 'KEYBOARD_MODEL=%q\n' "$KEYBOARD_MODEL"
    printf 'KEYBOARD_VARIANT=%q\n' "$KEYBOARD_VARIANT"
    printf 'KEYBOARD_OPTIONS=%q\n' "$KEYBOARD_OPTIONS"
    printf '\n'
    printf 'REPORT_ENABLED=%q\n' "$REPORT_ENABLED"
    printf 'REPORT_GITHUB_OWNER=%q\n' "$REPORT_GITHUB_OWNER"
    printf 'REPORT_GITHUB_REPO=%q\n' "$REPORT_GITHUB_REPO"
    printf 'REPORT_GITHUB_REF=%q\n' "$REPORT_GITHUB_REF"
    printf 'REPORT_PATH=%q\n' "$REPORT_PATH"
    printf 'REPORT_TOKEN_FILE=%q\n' "/etc/kiosk/report.token"
    printf 'REPORT_LOG_LINES=%q\n' "200"
    printf '\n'
    printf 'LOCAL_HIDDEN_FILE=%q\n' "/etc/kiosk/hidden-urls.local"
    printf 'LOCAL_SITES_FILE=%q\n' "/etc/kiosk/local-sites.local"
    printf 'ADMIN_PIN_FILE=%q\n' "/etc/kiosk/admin.pin"
    printf 'ADMIN_UI_PORT=%q\n' "$ADMIN_UI_PORT"
    printf '\n'
    printf '# Program önfrissítés (GitHub Releases) - kiosk-update.timer\n'
    printf 'UPDATE_ENABLED=%q\n' "$UPDATE_ENABLED"
    printf 'UPDATE_GITHUB_OWNER=%q\n' "$UPDATE_GITHUB_OWNER"
    printf 'UPDATE_GITHUB_REPO=%q\n' "$UPDATE_GITHUB_REPO"
    printf 'UPDATE_TOKEN_FILE=%q\n' "/etc/kiosk/update.token"
    printf 'UPDATE_INTERVAL_MINUTES=%q\n' "$UPDATE_INTERVAL_MINUTES"
    printf 'UPDATE_WINDOW=%q\n' "$UPDATE_WINDOW"
    printf 'UPDATE_REQUIRE_CHECKSUM=%q\n' "$UPDATE_REQUIRE_CHECKSUM"
    printf 'UPDATE_SETUP_DIR=%q\n' "$UPDATE_SETUP_DIR"
} >/etc/kiosk/kiosk.conf
chmod 0644 /etc/kiosk/kiosk.conf

if [ -n "$TOKEN" ]; then
    umask 077
    printf '%s\n' "$TOKEN" >/etc/kiosk/github.token
    umask 022
fi
chown root:root /etc/kiosk/github.token
chmod 600 /etc/kiosk/github.token

if [ -n "$REPORT_TOKEN" ]; then
    umask 077
    printf '%s\n' "$REPORT_TOKEN" >/etc/kiosk/report.token
    umask 022
fi
if [ -s /etc/kiosk/report.token ]; then
    chown root:root /etc/kiosk/report.token
    chmod 600 /etc/kiosk/report.token
fi

if [ -n "$WRITE_TOKEN" ]; then
    umask 077
    printf '%s\n' "$WRITE_TOKEN" >/etc/kiosk/github-write.token
    umask 022
fi
if [ -s /etc/kiosk/github-write.token ]; then
    chown root:root /etc/kiosk/github-write.token
    chmod 600 /etc/kiosk/github-write.token
fi

if [ -n "$UPDATE_TOKEN" ]; then
    umask 077
    printf '%s\n' "$UPDATE_TOKEN" >/etc/kiosk/update.token
    umask 022
fi
if [ -s /etc/kiosk/update.token ]; then
    chown root:root /etc/kiosk/update.token
    chmod 600 /etc/kiosk/update.token
fi

if [ -n "$ADMIN_PIN" ]; then
    if ! ADMIN_PIN_FILE=/etc/kiosk/admin.pin pin_store "$ADMIN_PIN"; then
        log "WARN" "Az admin PIN mentése nem sikerült."
        ADMIN_PIN=""
    fi
fi

# --- admin felület -----------------------------------------------------------
step "Admin felület (GitHub allowlist szerkesztő)"
if [ "$ADMIN_ENABLED" = "1" ]; then
    say "PIN beállítva; a felület: Ctrl+Alt+A a kezdőlapon (127.0.0.1:${ADMIN_UI_PORT})"
else
    say "Nincs admin PIN - a helyi engedélyező felület kikapcsolva."
fi

# --- belépéskori jelentés ----------------------------------------------------
step "Belépéskori jelentés"
if [ "$REPORT_ENABLED" = "1" ]; then
    install -d -m 0755 /usr/share/pam-configs
    install -m 0644 "${SRC_DIR}/pam/kiosk-login-report" \
        /usr/share/pam-configs/kiosk-login-report
    if command -v pam-auth-update >/dev/null 2>&1; then
        pam-auth-update --enable kiosk-login-report >/dev/null 2>&1 || \
            log "WARN" "A PAM-profil engedélyezése nem sikerült (kézzel: pam-auth-update --enable kiosk-login-report)."
        say "PAM: minden login/sshd belépéskor fut (háttérben)"
    else
        log "WARN" "pam-auth-update nem található - a jelentés nem indul el automatikusan."
    fi
else
    if command -v pam-auth-update >/dev/null 2>&1; then
        pam-auth-update --remove kiosk-login-report >/dev/null 2>&1 || true
    fi
    rm -f /usr/share/pam-configs/kiosk-login-report
    say "Belépéskori jelentés: kikapcsolva"
fi

# --- systemd egységek -------------------------------------------------------
step "Systemd egységek"
render_unit() {
    local src="$1" dest="$2"
    sed -e "s|@KIOSK_USER@|${KIOSK_USER}|g" \
        -e "s|@KIOSK_HOME@|${KIOSK_HOME}|g" \
        -e "s|@REFRESH_MINUTES@|${REFRESH_MINUTES}|g" \
        -e "s|@TINYPROXY_BIN@|${TINYPROXY_BIN}|g" \
        -e "s|@ADMIN_UI_PORT@|${ADMIN_UI_PORT}|g" \
        -e "s|@GITHUB_OWNER@|${GITHUB_OWNER}|g" \
        -e "s|@GITHUB_REPO@|${GITHUB_REPO}|g" \
        -e "s|@GITHUB_REF@|${GITHUB_REF}|g" \
        -e "s|@GITHUB_PATH@|${GITHUB_PATH}|g" \
        -e "s|@GITHUB_TOKEN_FILE@|/etc/kiosk/github.token|g" \
        -e "s|@GITHUB_WRITE_TOKEN_FILE@|/etc/kiosk/github-write.token|g" \
        -e "s|@PROXY_BYPASS_MINUTES@|${PROXY_BYPASS_MINUTES}|g" \
        -e "s|@INBOX_DIR@|/srv/kiosk/inbox|g" \
        -e "s|@UPDATE_INTERVAL_MINUTES@|${UPDATE_INTERVAL_MINUTES}|g" \
        "$src" >"$dest"
    chmod 0644 "$dest"
}

render_unit "${SRC_DIR}/systemd/kiosk-sync.service" /etc/systemd/system/kiosk-sync.service
render_unit "${SRC_DIR}/systemd/kiosk-sync.timer" /etc/systemd/system/kiosk-sync.timer
render_unit "${SRC_DIR}/systemd/kiosk-proxy.service" /etc/systemd/system/kiosk-proxy.service
render_unit "${SRC_DIR}/systemd/kiosk-docs.service" /etc/systemd/system/kiosk-docs.service
render_unit "${SRC_DIR}/systemd/kiosk-docs.path" /etc/systemd/system/kiosk-docs.path
render_unit "${SRC_DIR}/systemd/kiosk-usb-import@.service" /etc/systemd/system/kiosk-usb-import@.service
render_unit "${SRC_DIR}/systemd/kiosk-admin-ui.service" /etc/systemd/system/kiosk-admin-ui.service
render_unit "${SRC_DIR}/systemd/kiosk-update.service" /etc/systemd/system/kiosk-update.service
render_unit "${SRC_DIR}/systemd/kiosk-update.timer" /etc/systemd/system/kiosk-update.timer

install -m 0644 "${SRC_DIR}/systemd/logind-kiosk.conf" /etc/systemd/logind.conf.d/99-kiosk.conf
sed -e "s|@KIOSK_USER@|${KIOSK_USER}|g" \
    "${SRC_DIR}/systemd/kiosk-tmpfiles.conf" >/usr/lib/tmpfiles.d/kiosk.conf
chmod 0644 /usr/lib/tmpfiles.d/kiosk.conf

if [ "$USB_IMPORT" = "1" ]; then
    install -m 0644 "${SRC_DIR}/udev/99-kiosk-usb.rules" /etc/udev/rules.d/99-kiosk-usb.rules
fi

# --- autologin --------------------------------------------------------------
step "Autologin a tty1-en"
systemctl enable getty@tty1.service >/dev/null 2>&1 || true
cat >/etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${KIOSK_USER} --noclear %I \$TERM
Type=idle
EOF
chmod 0644 /etc/systemd/system/getty@tty1.service.d/autologin.conf

cat >"${KIOSK_HOME}/.bash_profile" <<'EOF'
# Debian kiosk - a tty1-en automatikusan indul a böngésző.
if [ "$(tty 2>/dev/null)" = "/dev/tty1" ] && [ -z "${KIOSK_LOOP_ACTIVE:-}" ]; then
    export KIOSK_LOOP_ACTIVE=1
    exec /usr/local/bin/kiosk-session.sh
fi
EOF
chown "${KIOSK_USER}:${KIOSK_USER}" "${KIOSK_HOME}/.bash_profile"
chmod 0644 "${KIOSK_HOME}/.bash_profile"

# --- első szinkron + renderelés --------------------------------------------
step "Allowlist letöltése és a felület legyártása"
systemd-tmpfiles --create /usr/lib/tmpfiles.d/kiosk.conf >/dev/null 2>&1 || true
if /usr/local/bin/kiosk-sync.sh; then
    say "GitHub allowlist betöltve."
elif [ -s "${KIOSK_HOME}/state/allowlist.json" ]; then
    # Újratelepítés/frissítés: a korábbi, működő lista marad.
    log "WARN" "A GitHub szinkron nem sikerült - a korábbi allowlist marad érvényben."
else
    log "WARN" "Az első GitHub szinkron nem sikerült - a beépített minta listát használjuk."
    jq -f /usr/lib/kiosk/allowlist.jq "${SRC_DIR}/examples/allowlist.json" \
        >"${KIOSK_HOME}/state/allowlist.json"
    chown "${KIOSK_USER}:${KIOSK_USER}" "${KIOSK_HOME}/state/allowlist.json"
fi
# Mindig újrarendereljük: a sync változatlan listánál nem renderel, de az új
# programverzió (kezdőlap lábléc, sablonok) csak így kerül ki.
KIOSK_NO_RELOAD=1 /usr/local/bin/kiosk-render.sh ||
    log "WARN" "A felület újragenerálása nem sikerült."

runuser -u "$KIOSK_USER" -- /usr/local/bin/kiosk-docs.sh >/dev/null 2>&1 || \
    log "WARN" "A dokumentumlista inicializálása nem sikerült."

# --- szolgáltatások ---------------------------------------------------------
step "Szolgáltatások engedélyezése"
systemctl daemon-reload
systemctl enable kiosk-sync.timer kiosk-docs.path kiosk-docs.service >/dev/null

if [ "$ENFORCE_ALLOWLIST" = "1" ]; then
    systemctl enable kiosk-proxy.service >/dev/null
    systemctl reset-failed kiosk-proxy.service >/dev/null 2>&1 || true
    systemctl restart kiosk-proxy.service || log "WARN" "A proxy nem indult el."
    sleep 1
    if ! systemctl is-active --quiet kiosk-proxy.service; then
        log "ERROR" "A kiosk-proxy.service nem fut - a böngésző így hálózati hibát mutatna."
        journalctl -u kiosk-proxy.service -n 15 --no-pager 2>/dev/null | sed 's/^/    /' >&2 || true
        log "WARN" "Átmenetileg könyvjelző-módra váltok (ENFORCE_ALLOWLIST=0), hogy a kiosk használható legyen."
        log "WARN" "A proxyt javítsd, majd: kiosk-admin.sh doctor"
        sed -i 's/^ENFORCE_ALLOWLIST=.*/ENFORCE_ALLOWLIST=0/' /etc/kiosk/kiosk.conf
        ENFORCE_ALLOWLIST=0
        systemctl disable --now kiosk-proxy.service >/dev/null 2>&1 || true
        /usr/local/bin/kiosk-render.sh >/dev/null 2>&1 || true
    else
        say "Allowlist proxy fut: 127.0.0.1:${PROXY_PORT}"
    fi
else
    systemctl disable kiosk-proxy.service >/dev/null 2>&1 || true
    systemctl stop kiosk-proxy.service >/dev/null 2>&1 || true
fi

if [ "$ADMIN_ENABLED" = "1" ]; then
    systemctl enable kiosk-admin-ui.service >/dev/null 2>&1 || true
    systemctl reset-failed kiosk-admin-ui.service >/dev/null 2>&1 || true
    systemctl restart kiosk-admin-ui.service >/dev/null 2>&1 || \
        log "WARN" "Az admin felület szolgáltatása nem indult el."
    if systemctl is-active --quiet kiosk-admin-ui.service; then
        say "Admin felület fut: 127.0.0.1:${ADMIN_UI_PORT}"
    else
        log "WARN" "Az admin felület nem fut (journalctl -u kiosk-admin-ui)."
    fi
else
    systemctl disable --now kiosk-admin-ui.service >/dev/null 2>&1 || true
fi

systemctl start kiosk-docs.path >/dev/null 2>&1 || true
systemctl start kiosk-sync.timer >/dev/null 2>&1 || true

if [ "$UPDATE_ENABLED" = "1" ]; then
    systemctl enable kiosk-update.timer >/dev/null 2>&1 || true
    # restart helyett start: frissítés közben a futó kiosk-update.service-t
    # nem szabad megszakítani.
    systemctl start kiosk-update.timer >/dev/null 2>&1 || true
else
    systemctl disable --now kiosk-update.timer >/dev/null 2>&1 || true
fi

if [ "$USB_IMPORT" = "1" ]; then
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger --action=add --subsystem-match=block 2>/dev/null || true
fi

systemctl set-default multi-user.target >/dev/null 2>&1 || true

# A logind beállításai (power gomb, NAutoVTs) újraindítás után lépnek életbe.
# A logind újraindítását szándékosan elkerüljük: SSH-s session-t szakíthat meg.

# --- telepítési forrás megőrzése (önfrissítés / visszaállás) ----------------
# A sikeresen telepített kiadás forrása a ${UPDATE_SETUP_DIR}/releases/<verzió>
# alá kerül, a "current" link mindig erre mutat. A kiosk-update.sh hiba esetén
# innen állítja vissza az előző verziót.
step "Telepítési forrás mentése (${UPDATE_SETUP_DIR})"
install -m 0644 "${SRC_DIR}/VERSION" /usr/share/kiosk/VERSION
rel_dir="${UPDATE_SETUP_DIR}/releases/${KIOSK_VERSION}"
install -d -m 0755 "${UPDATE_SETUP_DIR}/releases"
if [ "$(readlink -f "$SRC_DIR")" != "$(readlink -f "$rel_dir" 2>/dev/null || echo "$rel_dir")" ]; then
    rm -rf -- "${rel_dir}.tmp"
    install -d -m 0755 "${rel_dir}.tmp"
    tar -C "$SRC_DIR" --exclude=./.git -cf - . | tar -C "${rel_dir}.tmp" -xf - --no-same-owner
    rm -rf -- "$rel_dir"
    mv -- "${rel_dir}.tmp" "$rel_dir"
fi
ln -sfn "$rel_dir" "${UPDATE_SETUP_DIR}/current"
say "Forrás: ${rel_dir}"

# --- összefoglaló -----------------------------------------------------------
step "Kész"
cat <<EOF
    Kiosk felhasználó : ${KIOSK_USER}
    Profil            : ${KIOSK_HOME}/firefox
    Kezdőlap          : /srv/kiosk/start.html
    Dokumentumok      : /srv/kiosk/docs  (inbox: /srv/kiosk/inbox)
    GitHub forrás     : ${GITHUB_OWNER}/${GITHUB_REPO}/${GITHUB_PATH}@${GITHUB_REF}
    Token             : /etc/kiosk/github.token (root:root, 0600)
    Nyelv/billentyűzet: ${KIOSK_LANG} / ${KEYBOARD_LAYOUT} (${KEYBOARD_MODEL})
    Belépés jelentés  : $([ "$REPORT_ENABLED" = 1 ] && echo "${REPORT_GITHUB_OWNER}/${REPORT_GITHUB_REPO}/${REPORT_PATH} (PAM, háttérben)" || echo "kikapcsolva")
    Verzió            : ${KIOSK_VERSION}
    Önfrissítés       : $([ "$UPDATE_ENABLED" = 1 ] && echo "${UPDATE_GITHUB_OWNER}/${UPDATE_GITHUB_REPO} (kiosk-update.timer, ${UPDATE_INTERVAL_MINUTES} perc)" || echo "kikapcsolva")
    Admin felület     : $([ "$ADMIN_ENABLED" = 1 ] && echo "127.0.0.1:${ADMIN_UI_PORT} (Ctrl+Alt+A)" || echo "kikapcsolva (nincs PIN)")
    Admin írás        : $([ -s /etc/kiosk/github-write.token ] && echo "write token beállítva" || echo "nincs (csak olvasás)")

    Ellenőrzés:  kiosk-admin.sh status
    Frissítés :  kiosk-admin.sh update
    Program   :  kiosk-admin.sh self-update --check
    Jelentés  :  kiosk-admin.sh report --dry-run
    Engedély  :  kiosk-admin.sh allow https://pelda.hu/
    Napló     :  kiosk-admin.sh logs 100
EOF

if [ "$(tty 2>/dev/null)" = "/dev/tty1" ]; then
    printf '\n    FIGYELEM: tty1-en vagy, ezért a getty-t nem indítottam újra.\n'
    printf '    Indítsd újra: systemctl restart getty@tty1\n'
else
    systemctl restart getty@tty1.service >/dev/null 2>&1 || \
        log "WARN" "A getty@tty1 újraindítása nem sikerült."
    printf '\n    A böngésző a tty1-en indul (autologin).\n'
fi
