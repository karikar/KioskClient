#!/usr/bin/env bash
# =============================================================================
# Debian kiosk - allowlist szinkronizálás privát GitHub repóból
#
# 1. letölti az allowlist.json-t a GitHub API-ról (token a fájlból, nem argv-ből)
# 2. validálja és normalizálja
# 3. változás esetén frissíti a cache-t és újrarendereli a kiosk felületet
# 4. kéri a futó böngésző újraindítását
#
# Hibánál a korábbi (működő) lista marad érvényben.
# =============================================================================
set -euo pipefail

export LOG_NAME="kiosk-sync"
# shellcheck source=/usr/lib/kiosk/common.sh
: "${KIOSK_PREFIX:=/usr}"
. "${KIOSK_PREFIX}/lib/kiosk/common.sh"
# shellcheck source=/usr/lib/kiosk/render.sh
. "${KIOSK_PREFIX}/lib/kiosk/render.sh"
load_conf
require_root

[ -n "${GITHUB_OWNER}" ] || die "GITHUB_OWNER nincs beállítva a ${KIOSK_CONF} fájlban"
[ -n "${GITHUB_REPO}" ] || die "GITHUB_REPO nincs beállítva a ${KIOSK_CONF} fájlban"

token_file="${GITHUB_TOKEN_FILE}"
[ -r "$token_file" ] || die "Hiányzó token fájl: ${token_file} (root:root, 0600)"

token="$(tr -d '[:space:]' <"$token_file")"
[ -n "$token" ] || die "Üres token: ${token_file}"

perm="$(stat -c '%a' "$token_file")"
case "$perm" in
    600 | 400 | 640 | 440) ;;
    *) log "WARN" "A token fájl jogosultsága ${perm}; ajánlott a 600." ;;
esac

api="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/contents/${GITHUB_PATH}?ref=${GITHUB_REF}"

raw="$(mktemp)"
norm="$(mktemp)"
curl_cfg="$(mktemp)"
hdr="$(mktemp)"
jq_err_file="$(mktemp)"
trap 'rm -f -- "$raw" "$norm" "$curl_cfg" "$hdr" "$jq_err_file"' EXIT
chmod 600 "$curl_cfg"
printf 'header = "Authorization: Bearer %s"\n' "$token" >"$curl_cfg"

log "INFO" "Allowlist letöltése: ${GITHUB_OWNER}/${GITHUB_REPO}/${GITHUB_PATH}@${GITHUB_REF}"

http_code="$(curl --silent --show-error --location \
    --proto '=https' \
    --max-time 45 --max-filesize 1048576 \
    --retry 3 --retry-delay 2 --retry-all-errors \
    --config "$curl_cfg" \
    -D "$hdr" \
    -H 'Accept: application/vnd.github.raw+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    -H "User-Agent: debian-kiosk/${KIOSK_VERSION}" \
    -o "$raw" -w '%{http_code}' "$api")" || {
    log "ERROR" "Hálózati hiba a letöltés közben - a korábbi lista marad"
    exit 1
}

case "$http_code" in
    200) ;;
    401 | 403)
        log "ERROR" "Hitelesítési hiba (HTTP ${http_code}). Lejárt a token, vagy hiányzik a Contents: Read jog."
        exit 1
        ;;
    404)
        log "ERROR" "HTTP 404: nincs ilyen repó/fájl/ág (${GITHUB_OWNER}/${GITHUB_REPO}/${GITHUB_PATH}@${GITHUB_REF})"
        exit 1
        ;;
    *)
        log "ERROR" "Váratlan HTTP státusz: ${http_code}"
        exit 1
        ;;
esac

if [ ! -s "$raw" ]; then
    log "ERROR" "A GitHub üres fájlt adott vissza (HTTP 200) - ellenőrizd a GITHUB_PATH/ág beállítást"
    exit 1
fi

size="$(wc -c <"$raw" | tr -d '[:space:]')"
ctype="$(grep -i '^content-type:' "$hdr" 2>/dev/null | tail -n 1 | cut -d: -f2- | sed 's/^[[:space:]]*//' | tr -d '\r')" || ctype=""

# A jq 1.6 nem szereti a UTF-8 BOM-ot; ha van, távolítsuk el.
if [ "$(head -c 3 "$raw" | od -An -tx1 | tr -d '[:space:]')" = "efbbbf" ]; then
    log "WARN" "A letöltött fájl UTF-8 BOM-mal kezdődött - eltávolítva"
    tail -c +4 "$raw" >"${raw}.nobom" && mv -f "${raw}.nobom" "$raw"
fi

if ! jq_type="$(jq -r 'type' "$raw" 2>"$jq_err_file")"; then
    snippet="$(head -c 200 "$raw" | tr '\r\n\t' '   ' | tr -cd '[:print:]' | cut -c1-200)"
    log "ERROR" "A letöltött fájl nem érvényes JSON (${size} byte, Content-Type: ${ctype:-ismeretlen})"
    case "$ctype" in
        *text/html* | *application/xhtml*)
            log "ERROR" "HTML válasz érkezett - valószínűleg captive portal vagy proxy, nem a GitHub fájl."
            ;;
    esac
    log "ERROR" "jq: $(head -n 1 "$jq_err_file" 2>/dev/null)"
    log "ERROR" "Eleje: ${snippet}"
    exit 1
fi

if [ "$jq_type" != "object" ]; then
    snippet="$(head -c 200 "$raw" | tr '\r\n\t' '   ' | tr -cd '[:print:]' | cut -c1-200)"
    log "ERROR" "A letöltött fájl JSON, de nem objektum (típus: ${jq_type:-üres}; ${size} byte)"
    log "ERROR" "Eleje: ${snippet}"
    exit 1
fi

jq -f "${KIOSK_LIB:-/usr/lib/kiosk}/allowlist.jq" "$raw" >"$norm" ||
    die "Normalizálási hiba (allowlist.jq)"

if ! validate_allowlist "$norm"; then
    log "ERROR" "Az allowlist nem felel meg a sémának - a korábbi lista marad"
    log "ERROR" "Részletek: lásd README (Allowlist séma)"
    exit 1
fi

install -d -m 0755 "$KIOSK_STATE"
cached="${KIOSK_STATE}/allowlist.json"

new_sum="$(jq -S -c '.' "$norm" | sha256sum | cut -d' ' -f1)"
old_sum=""
if [ -r "$cached" ]; then
    old_sum="$(jq -S -c '.' "$cached" 2>/dev/null | sha256sum | cut -d' ' -f1)"
fi

if [ -n "$old_sum" ] && [ "$new_sum" = "$old_sum" ]; then
    log "INFO" "Nincs változás (${GITHUB_OWNER}/${GITHUB_REPO}), $(jq -r '.site_count' "$norm") oldal"
    exit 0
fi

atomic_install "$norm" "$cached" 0644 root root ||
    die "Nem sikerült a cache írása: ${cached}"

log "INFO" "Allowlist frissítve: $(jq -r '.site_count' "$norm") oldal, $(jq -r '.domains | length' "$norm") domain"

render_all "$cached"

if [ "${ENFORCE_ALLOWLIST:-1}" = "1" ] && systemctl is-active --quiet kiosk-proxy.service 2>/dev/null; then
    systemctl try-restart kiosk-proxy.service 2>/dev/null || \
        log "WARN" "A kiosk-proxy.service újraindítása nem sikerült"
fi

notify_session_reload
