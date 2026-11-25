#!/usr/bin/env bash
# =============================================================================
# Debian kiosk - közös függvénytár
#
# Minden kiosk script ezt tölti be:
#   . /usr/lib/kiosk/common.sh
# =============================================================================

# A verzió forrása a VERSION fájl: a forrásfában a lib/ mellett, telepítve a
# /usr/share/kiosk/VERSION. Környezeti változóval felülírható.
if [ -z "${KIOSK_VERSION:-}" ]; then
    for _kv_file in "$(dirname -- "${BASH_SOURCE[0]}")/../VERSION" /usr/share/kiosk/VERSION; do
        if [ -r "$_kv_file" ]; then
            KIOSK_VERSION="$(tr -d '[:space:]' <"$_kv_file")"
            break
        fi
    done
    unset _kv_file
fi
: "${KIOSK_VERSION:=1.0.0}"
: "${LOG_NAME:=kiosk}"

# --- naplózás ---------------------------------------------------------------
log() {
    local level="$1"
    shift
    local msg="$*"
    local prio
    prio="$(printf '%s' "$level" | tr '[:upper:]' '[:lower:]')"
    printf '%s [%-5s] %s\n' "$(date '+%F %T')" "$level" "$msg" >&2
    if command -v logger >/dev/null 2>&1; then
        logger -t "kiosk-${LOG_NAME#kiosk-}" -p "user.${prio}" -- "$msg" 2>/dev/null || true
    fi
}

die() {
    log "ERROR" "$*"
    exit 1
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "Ehhez root jogosultság kell (sudo)."
}

# --- konfiguráció -----------------------------------------------------------
load_conf() {
    local conf="${KIOSK_CONF:-/etc/kiosk/kiosk.conf}"
    [ -r "$conf" ] || die "Nem olvasható a konfiguráció: $conf"
    # shellcheck disable=SC1090
    . "$conf"
    KIOSK_CONF="$conf"
    export KIOSK_CONF

    : "${KIOSK_USER:=kiosk}"
    : "${KIOSK_HOME:=/var/lib/kiosk}"
    : "${KIOSK_PROFILE:=$KIOSK_HOME/firefox}"
    : "${KIOSK_DOWNLOADS:=$KIOSK_HOME/Downloads}"
    : "${KIOSK_STATE:=$KIOSK_HOME/state}"
    : "${KIOSK_RUN:=/run/kiosk}"
    : "${KIOSK_ETC:=/etc/kiosk}"
    : "${KIOSK_LIB:=/usr/lib/kiosk}"
    : "${KIOSK_WEB_DIR:=/usr/share/kiosk/web}"
    : "${KIOSK_FIREFOX_DIR:=/usr/share/kiosk/firefox}"
    : "${KIOSK_PROXY_TEMPLATE:=/usr/share/kiosk/proxy/tinyproxy.conf.in}"
    : "${START_PAGE:=/srv/kiosk/start.html}"
    : "${DOCS_DIR:=/srv/kiosk/docs}"
    : "${INBOX_DIR:=/srv/kiosk/inbox}"
    : "${PROXY_FILTER:=$KIOSK_ETC/proxy-filter}"
    : "${PROXY_CONF:=$KIOSK_ETC/tinyproxy.conf}"
    : "${PROXY_PORT:=8877}"
    : "${ENFORCE_ALLOWLIST:=1}"
    : "${PROXY_BYPASS_MINUTES:=15}"
    : "${KIOSK_BYPASS_FILE:=${KIOSK_RUN}/proxy-bypass}"
    : "${USB_IMPORT:=1}"
    : "${USB_IMPORT_MODE:=manual}"
    : "${SITE_NAME:=Kiosk}"
    : "${MAX_FILE_MB:=2048}"
    : "${KIOSK_LANG:=hu_HU.UTF-8}"
    : "${KEYBOARD_LAYOUT:=hu}"
    : "${KEYBOARD_MODEL:=pc105}"
    : "${KEYBOARD_VARIANT:=}"
    : "${KEYBOARD_OPTIONS:=}"
    : "${GITHUB_OWNER:=}"
    : "${GITHUB_REPO:=}"
    : "${GITHUB_REF:=main}"
    : "${GITHUB_PATH:=allowlist.json}"
    : "${GITHUB_TOKEN_FILE:=$KIOSK_ETC/github.token}"
    : "${GITHUB_WRITE_TOKEN_FILE:=$KIOSK_ETC/github-write.token}"

    # --- belépéskori jelentés -------------------------------------------
    : "${REPORT_ENABLED:=0}"
    : "${REPORT_GITHUB_OWNER:=${GITHUB_OWNER}}"
    : "${REPORT_GITHUB_REPO:=${GITHUB_REPO}}"
    : "${REPORT_GITHUB_REF:=${GITHUB_REF}}"
    : "${REPORT_PATH:=login-logs}"
    : "${REPORT_TOKEN_FILE:=$KIOSK_ETC/report.token}"
    : "${REPORT_LOG_LINES:=200}"

    # --- helyi, rejtett engedélyezés / admin UI -------------------------
    : "${LOCAL_HIDDEN_FILE:=$KIOSK_ETC/hidden-urls.local}"
    : "${LOCAL_SITES_FILE:=$KIOSK_ETC/local-sites.local}"
    : "${ADMIN_PIN_FILE:=$KIOSK_ETC/admin.pin}"
    : "${ADMIN_UI_PORT:=8878}"

    # --- program önfrissítés (GitHub Releases) --------------------------
    : "${UPDATE_ENABLED:=1}"
    : "${UPDATE_GITHUB_OWNER:=${GITHUB_OWNER}}"
    : "${UPDATE_GITHUB_REPO:=KioskClient}"
    : "${UPDATE_TOKEN_FILE:=$KIOSK_ETC/update.token}"
    : "${UPDATE_API_BASE:=https://api.github.com}"
    : "${UPDATE_ASSET_PREFIX:=debian-kiosk}"
    : "${UPDATE_INTERVAL_MINUTES:=60}"
    : "${UPDATE_WINDOW:=}"
    : "${UPDATE_REQUIRE_CHECKSUM:=1}"
    : "${UPDATE_SETUP_DIR:=/opt/kiosk-setup}"
    : "${UPDATE_KEEP_RELEASES:=2}"
    : "${KIOSK_VERSION_FILE:=/usr/share/kiosk/VERSION}"
}

# --- verziók ----------------------------------------------------------------
# "v1.2.3" -> "1.2.3"; érvénytelen formátumnál hibával tér vissza.
version_normalize() {
    local v="${1:-}"
    v="${v#[vV]}"
    [[ "$v" =~ ^[0-9]+(\.[0-9]+){1,3}(-[0-9A-Za-z.]+)?$ ]] || return 1
    printf '%s' "$v"
}

# Igaz, ha $1 szigorúan újabb, mint $2 (sort -V szerint).
version_gt() {
    local a="${1:-}" b="${2:-}"
    [ -n "$a" ] || return 1
    [ -n "$b" ] || return 0
    [ "$a" != "$b" ] || return 1
    [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n 1)" = "$a" ]
}

# A telepített programverzió (a telepítő írja a VERSION fájlt).
installed_version() {
    local f="${KIOSK_VERSION_FILE:-/usr/share/kiosk/VERSION}"
    if [ -r "$f" ]; then
        tr -d '[:space:]' <"$f"
    else
        printf '%s' "${KIOSK_VERSION:-0.0.0}"
    fi
}

# --- HTML / URL segédek -----------------------------------------------------
html_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    s="${s//\'/&#39;}"
    printf '%s' "$s"
}

# Abszolút útvonal -> file:// URL (szegmensenként URL-kódolva)
file_url() {
    local p="$1"
    printf 'file://%s' "$(jq -rn --arg p "$p" '$p | split("/") | map(@uri) | join("/")')"
}

# --- fájlműveletek ----------------------------------------------------------
sha256_file() {
    sha256sum -- "$1" | cut -d' ' -f1
}

# Atomikus másolás: az átmeneti fájl ugyanabban a könyvtárban készül, majd mv.
atomic_install() {
    local src="$1" dest="$2" mode="${3:-0644}" owner="${4:-root}" group="${5:-root}"
    local tmp
    tmp="$(mktemp "${dest}.tmp.XXXXXX")" || return 1
    if ! cp -- "$src" "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    chmod "$mode" "$tmp" 2>/dev/null || true
    chown "${owner}:${group}" "$tmp" 2>/dev/null || true
    if ! mv -f -- "$tmp" "$dest"; then
        rm -f -- "$tmp"
        return 1
    fi
}

# --- allowlist validáció ----------------------------------------------------
# A bemenet a normalizált szerkezet (lib/allowlist.jq kimenete).
validate_allowlist() {
    local file="$1"
    [ -r "$file" ] || return 1
    jq -e '
        (.sites | type) == "array"
        and (.sites | length) >= 1
        and (.sites | length) <= 300
        and (.start_url | type) == "string"
        and (.start_url | test("^https?://"))
        and ([.sites[].url] | unique | length) == (.sites | length)
        and all(.sites[];
              (.url | type) == "string"
              and (.url | test("^https?://[^\\s\"<>]+$"))
              and (.url | length) <= 2048
              and (.title | type) == "string"
              and (.title | length) >= 1
              and (.title | length) <= 80
              and ((.allowed == null) or ((.allowed | type) == "boolean")))
        and (.refresh_interval_seconds | type) == "number"
        and (.refresh_interval_seconds >= 30)
        and (.refresh_interval_seconds <= 86400)
        and ((.resolution // "") as $r
             | (($r | type) == "string")
               and ($r | test("^$|^[0-9]{3,4}x[0-9]{3,4}$")))
        and (.domains | type) == "array"
        and (.domains | length) >= 1
        and all(.domains[];
              (type == "string")
              and (length >= 1)
              and (length <= 253)
              and test("^[a-z0-9*][a-z0-9.*-]*$"))
    ' "$file" >/dev/null 2>&1
}

# --- helyi, rejtett engedélyezés -------------------------------------------
# Egy URL-ből vagy csupasz domainből kinyeri a szűrőhöz használt hostot.
# Csak a proxy domainlistájára kerül, a menübe (sites) nem.
url_host() {
    local v="${1:-}" lv
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    lv="${v,,}"
    case "$lv" in
        http://* | https://*) v="${v#*://}" ;;
        *://*) return 1 ;;
    esac
    v="${v##*@}"
    v="${v%%[/?#]*}"
    v="${v%%:*}"
    v="${v,,}"
    v="${v%.}"
    v="${v#www.}"
    case "$v" in
        "" | *[!a-z0-9.*-]* | [!a-z0-9*]*) return 1 ;;
    esac
    printf '%s' "$v"
}

hidden_hosts() {
    local file="${LOCAL_HIDDEN_FILE:-${KIOSK_ETC}/hidden-urls.local}"
    local line host
    [ -r "$file" ] || return 0
    while IFS= read -r line; do
        line="${line%$'\r'}"
        case "$line" in "" | \#*) continue ;; esac
        host="$(url_host "$line")" || continue
        printf '%s\n' "$host"
    done <"$file"
}

# A helyben felvett, a főoldalon is megjelenő címek (egy URL soronként).
local_site_urls() {
    local file="${LOCAL_SITES_FILE:-${KIOSK_ETC}/local-sites.local}"
    local line
    [ -r "$file" ] || return 0
    while IFS= read -r line; do
        line="${line%$'\r'}"
        case "$line" in "" | \#*) continue ;; esac
        printf '%s\n' "$line"
    done <"$file"
}

hidden_add_url() {
    local input="${1:-}" host file tmp existing
    host="$(url_host "$input")" || return 1
    file="${LOCAL_HIDDEN_FILE:-${KIOSK_ETC}/hidden-urls.local}"
    install -d -m 0755 "$(dirname "$file")" 2>/dev/null || true
    existing="$(hidden_hosts)"
    if grep -qxF -- "$host" <<<"$existing"; then
        printf '%s\n' "$host"
        return 0
    fi
    tmp="$(mktemp "${file}.tmp.XXXXXX")" || return 1
    {
        [ -r "$file" ] && cat -- "$file"
        printf '%s\n' "$input"
    } >"$tmp"
    chmod 0600 "$tmp" 2>/dev/null || true
    chown root:root "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$file" || {
        rm -f -- "$tmp"
        return 1
    }
    printf '%s\n' "$host"
}

hidden_remove_host() {
    local want="${1:-}" file tmp line host found=1
    file="${LOCAL_HIDDEN_FILE:-${KIOSK_ETC}/hidden-urls.local}"
    [ -r "$file" ] || return 1
    tmp="$(mktemp "${file}.tmp.XXXXXX")" || return 1
    while IFS= read -r line; do
        host="$(url_host "$line")" || host=""
        if [ "$host" = "$want" ]; then
            found=0
            continue
        fi
        printf '%s\n' "$line"
    done <"$file" >"$tmp"
    if [ "$found" != 0 ]; then
        rm -f -- "$tmp"
        return 1
    fi
    chmod 0600 "$tmp" 2>/dev/null || true
    chown root:root "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$file"
}

local_site_remove_host() {
    local want="${1:-}" file tmp line host found=1
    file="${LOCAL_SITES_FILE:-${KIOSK_ETC}/local-sites.local}"
    [ -r "$file" ] || return 1
    tmp="$(mktemp "${file}.tmp.XXXXXX")" || return 1
    while IFS= read -r line; do
        host="$(url_host "$line")" || host=""
        if [ "$host" = "$want" ]; then
            found=0
            continue
        fi
        printf '%s\n' "$line"
    done <"$file" >"$tmp"
    if [ "$found" != 0 ]; then
        rm -f -- "$tmp"
        return 1
    fi
    chmod 0600 "$tmp" 2>/dev/null || true
    chown root:root "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$file"
}

# PIN tárolása salted SHA-256-ként, root-only fájlban.
pin_valid_format() {
    case "${1:-}" in
        "" | *[!0-9]*) return 1 ;;
    esac
    [ "${#1}" -ge 4 ] && [ "${#1}" -le 8 ]
}

pin_store() {
    local pin="${1:-}" file salt hash
    pin_valid_format "$pin" || return 1
    file="${ADMIN_PIN_FILE:-${KIOSK_ETC}/admin.pin}"
    install -d -m 0755 "$(dirname "$file")" 2>/dev/null || true
    salt="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    hash="$(printf '%s' "${salt}${pin}" | sha256sum | cut -d' ' -f1)"
    umask 077
    printf 'sha256:%s:%s\n' "$salt" "$hash" >"$file"
    umask 022
    chown root:root "$file" 2>/dev/null || true
    chmod 0600 "$file" 2>/dev/null || true
}

# --- ideiglenes proxy-feloldás ---------------------------------------------
# A fájl tartalma egy Unix időbélyeg (lejárat). Ha lejárt, töröljük.
proxy_bypass_active() {
    local file="${KIOSK_BYPASS_FILE:-${KIOSK_RUN:-/run/kiosk}/proxy-bypass}"
    local expiry now
    [ -r "$file" ] || return 1
    expiry="$(cat -- "$file" 2>/dev/null || true)"
    case "$expiry" in
        "" | *[!0-9]*)
            rm -f -- "$file" 2>/dev/null || true
            return 1
            ;;
    esac
    now="$(date +%s)"
    if [ "$now" -ge "$expiry" ]; then
        rm -f -- "$file" 2>/dev/null || true
        return 1
    fi
    return 0
}

# --- session újraindítás kérése --------------------------------------------
notify_session_reload() {
    local run_dir="${KIOSK_RUN:-/run/kiosk}"
    [ -d "$run_dir" ] || return 0
    if pgrep -u "${KIOSK_USER:-kiosk}" -x cage >/dev/null 2>&1; then
        : >"$run_dir/restart" 2>/dev/null || return 0
        chmod 0664 "$run_dir/restart" 2>/dev/null || true
        log "INFO" "A kiosk session a következő ellenőrzésnél újraindul"
    fi
}
