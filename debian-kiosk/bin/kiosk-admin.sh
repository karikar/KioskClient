#!/usr/bin/env bash
# =============================================================================
# Debian kiosk - üzemeltetői segédeszköz (root)
#
#   kiosk-admin.sh status          állapot
#   kiosk-admin.sh update          allowlist letöltése GitHubról
#   kiosk-admin.sh render          felület újragenerálása a cache-ből
#   kiosk-admin.sh restart         böngésző újraindítása
#   kiosk-admin.sh test <URL>      URL tesztelése a proxy allowliston
#   kiosk-admin.sh docs            inbox feldolgozása most
#   kiosk-admin.sh urls            engedélyezett oldalak listája
#   kiosk-admin.sh set-token       GitHub token cseréje
#   kiosk-admin.sh set-write-token GitHub write token cseréje (admin szerkesztés)
#   kiosk-admin.sh logs [N]        utolsó N naplósor
#   kiosk-admin.sh doctor          proxy/házirend diagnosztika
#   kiosk-admin.sh report          belépéskori jelentés küldése most (--dry-run)
#   kiosk-admin.sh allow [URL]     cím engedélyezése rejtve (menüben nem látszik)
#   kiosk-admin.sh hidden          helyben engedélyezett (rejtett) címek
#   kiosk-admin.sh unallow <host>  helyi rejtett engedélyezés törlése
#   kiosk-admin.sh set-pin         admin PIN beállítása az admin felülethez
#   kiosk-admin.sh version         telepített és legfrissebb programverzió
#   kiosk-admin.sh self-update     programfrissítés GitHubról (--check, --force)
#   kiosk-admin.sh set-update-token token privát program-repóhoz (Contents: Read)
# =============================================================================
set -uo pipefail

export LOG_NAME="kiosk-admin"
# shellcheck source=/usr/lib/kiosk/common.sh
: "${KIOSK_PREFIX:=/usr}"
. "${KIOSK_PREFIX}/lib/kiosk/common.sh"
load_conf
require_root

usage() {
    sed -n '3,23p' "$0" | sed 's/^# \{0,1\}//'
}

cached="${KIOSK_STATE}/allowlist.json"

case "${1:-status}" in
status)
    printf 'Kiosk állapot (v%s)\n' "$(installed_version)"
    printf '  Konfiguráció : %s\n' "${KIOSK_CONF}"
    printf '  Felhasználó  : %s\n' "${KIOSK_USER}"
    printf '  Forrás       : %s/%s/%s@%s\n' \
        "${GITHUB_OWNER:-?}" "${GITHUB_REPO:-?}" "${GITHUB_PATH}" "${GITHUB_REF}"

    if [ -r "$cached" ]; then
        hidden_count="$(jq -r '(.hidden_domains // []) | length' "$cached" 2>/dev/null || echo 0)"
        blocked_count="$(jq -r '[.sites[] | select(.allowed == false)] | length' "$cached" 2>/dev/null || echo 0)"
        printf '  Allowlist    : %s oldal, %s domain, %s rejtett, %s tiltott (módosítva: %s)\n' \
            "$(jq -r '.site_count' "$cached")" \
            "$(jq -r '.domains | length' "$cached")" \
            "${hidden_count:-0}" \
            "${blocked_count:-0}" \
            "$(date -r "$cached" '+%Y-%m-%d %H:%M')"
        printf '  Kezdőlap     : %s\n' "$(jq -r '.start_url' "$cached")"
        printf '  Felbontás    : %s\n' \
            "$(jq -r 'if (.resolution // "") == "" then "auto" else .resolution end' "$cached")"
    else
        printf '  Allowlist    : hiányzik (%s)\n' "$cached"
    fi

    if [ "${ENFORCE_ALLOWLIST:-1}" = "1" ]; then
        printf '  Proxy        : 127.0.0.1:%s (bekapcsolva)\n' "$PROXY_PORT"
        if proxy_bypass_active; then
            bypass_exp="$(cat -- "$KIOSK_BYPASS_FILE" 2>/dev/null || echo 0)"
            bypass_left=$(( bypass_exp - $(date +%s) ))
            [ "$bypass_left" -lt 0 ] && bypass_left=0
            printf '  Proxy bypass : aktív (%s perc hátra)\n' "$(( (bypass_left + 59) / 60 ))"
        fi
    else
        printf '  Proxy        : kikapcsolva (csak könyvjelzők)\n'
    fi

    if [ "${REPORT_ENABLED:-0}" = "1" ]; then
        printf '  Jelentés     : %s/%s/%s (PAM, bekapcsolva)\n' \
            "${REPORT_GITHUB_OWNER:-?}" "${REPORT_GITHUB_REPO:-?}" "${REPORT_PATH}"
    else
        printf '  Jelentés     : kikapcsolva\n'
    fi

    local_hidden="$(hidden_hosts | wc -l)"
    local_visible="$(local_site_urls | wc -l)"
    printf '  Helyi rejtett: %s cím (%s)\n' "${local_hidden// /}" "$LOCAL_HIDDEN_FILE"
    printf '  Helyi látható: %s cím (%s)\n' "${local_visible// /}" "$LOCAL_SITES_FILE"
    if [ -s "$GITHUB_WRITE_TOKEN_FILE" ]; then
        printf '  Admin írás   : beállítva (%s)\n' "$GITHUB_WRITE_TOKEN_FILE"
    else
        printf '  Admin írás   : nincs write token (csak olvasás)\n'
    fi
    if [ -s "$ADMIN_PIN_FILE" ]; then
        printf '  Admin felület: %s (127.0.0.1:%s, Ctrl+Alt+A)\n' \
            "$(systemctl is-active kiosk-admin-ui.service 2>/dev/null || true)" "$ADMIN_UI_PORT"
    else
        printf '  Admin felület: kikapcsolva (nincs PIN - kiosk-admin.sh set-pin)\n'
    fi

    if [ "${UPDATE_ENABLED:-1}" = "1" ]; then
        upd_info=""
        if [ -r "${KIOSK_STATE}/update-status" ]; then
            upd_info="$(awk -F= '
                $1 == "checked" { c = $2 }
                $1 == "latest"  { l = $2 }
                $1 == "result"  { r = $2 }
                END { printf "legutóbbi kiadás: %s, eredmény: %s, ellenőrizve: %s", (l == "" ? "?" : l), r, c }
            ' "${KIOSK_STATE}/update-status")"
        fi
        printf '  Önfrissítés  : %s/%s (%s)\n' "$UPDATE_GITHUB_OWNER" "$UPDATE_GITHUB_REPO" \
            "${upd_info:-még nem futott}"
    else
        printf '  Önfrissítés  : kikapcsolva (UPDATE_ENABLED=0)\n'
    fi

    printf '  Dokumentumok : %s fájl\n' \
        "$(find "$DOCS_DIR" -maxdepth 1 -type f ! -name 'index.html' ! -name '.origins' 2>/dev/null | wc -l)"

    printf '\n  Szolgáltatások:\n'
    for unit in kiosk-proxy.service kiosk-sync.timer kiosk-docs.path \
        kiosk-docs.service kiosk-admin-ui.service kiosk-update.timer; do
        state="$(systemctl is-active "$unit" 2>/dev/null || true)"
        printf '    %-22s %s\n' "$unit" "${state:-ismeretlen}"
    done

    if [ -r "$cached" ] && pgrep -u "$KIOSK_USER" -x cage >/dev/null 2>&1; then
        printf '    %-22s %s\n' "kiosk session" "fut"
    fi
    ;;

update)
    exec /usr/local/bin/kiosk-sync.sh
    ;;

render)
    exec /usr/local/bin/kiosk-render.sh
    ;;

version)
    printf 'Telepített verzió: %s\n' "$(installed_version)"
    /usr/local/bin/kiosk-update.sh --check
    rc=$?
    [ "$rc" = 10 ] && rc=0
    exit "$rc"
    ;;

self-update)
    shift || true
    exec /usr/local/bin/kiosk-update.sh "$@"
    ;;

set-update-token)
    printf 'GitHub token a program-repóhoz (%s/%s), fine-grained, Contents: Read.\n' \
        "$UPDATE_GITHUB_OWNER" "$UPDATE_GITHUB_REPO"
    printf 'Csak privát repóhoz kell. Üres bevitel = a token törlése. A bevitel nem látszik.\n'
    read -r -s -p 'Token: ' utoken || utoken=""
    printf '\n'
    if [ -z "$utoken" ]; then
        rm -f -- "$UPDATE_TOKEN_FILE"
        printf 'Update token törölve (nyilvános repó).\n'
    else
        umask 077
        printf '%s\n' "$utoken" >"$UPDATE_TOKEN_FILE"
        umask 022
        chmod 600 "$UPDATE_TOKEN_FILE"
        chown root:root "$UPDATE_TOKEN_FILE"
        printf 'Update token mentve: %s\n' "$UPDATE_TOKEN_FILE"
    fi
    ;;

restart)
    if pgrep -u "$KIOSK_USER" -x cage >/dev/null 2>&1; then
        notify_session_reload
        printf 'Újraindítási kérés elküldve (legfeljebb 3 mp).\n'
    else
        printf 'A kiosk session nem fut.\n'
    fi
    ;;

test)
    url="${2:-}"
    [ -n "$url" ] || die "Használat: $0 test <URL>"
    if [ "${ENFORCE_ALLOWLIST:-1}" != "1" ]; then
        printf 'A proxy allowlist ki van kapcsolva, a teszt nem értelmezhető.\n'
        exit 1
    fi
    err_file="$(mktemp)"
    hdr_file="$(mktemp)"
    body_file="$(mktemp)"
    code="$(curl --silent --show-error --dump-header "$hdr_file" --output "$body_file" \
        --write-out '%{http_code}' \
        --max-time 20 --proxy "http://127.0.0.1:${PROXY_PORT}" "$url" 2>"$err_file")"
    rc=$?
    if [ "$rc" -eq 0 ] && [ "$code" = "403" ]; then
        if grep -qiE 'cf-ray|server: *cloudflare|cf\.errors|cloudflare' "$hdr_file" "$body_file" 2>/dev/null; then
            printf 'HTTP 403 - a site (Cloudflare) utasította el, NEM a proxy allowlist: %s\n' "$url"
            printf '  Ez botvédelem/IP-korlátozás lehet; a böngésző challenge-e nem a proxy tiltása.\n'
        elif grep -qiE 'server: *tinyproxy|Ez az oldal nem érhető el' "$hdr_file" "$body_file" 2>/dev/null; then
            printf 'HTTP 403 - TILTVA (a proxy allowlist): %s\n' "$url"
        else
            printf 'HTTP 403 - a site vagy a proxy utasította el: %s\n' "$url"
            printf '  A gyökér 403 gyakran a CDN/site saját válasza; a konkrét asset útvonalat teszteld.\n'
        fi
    elif [ "$rc" -eq 0 ] && [ "$code" -ge 500 ] 2>/dev/null; then
        printf 'HTTP %s - a site/Cloudflare hibája, nem allowlist-probléma: %s\n' "$code" "$url"
    elif [ "$rc" -eq 0 ]; then
        printf 'HTTP %s - átengedve: %s\n' "$code" "$url"
    elif grep -q '403' "$err_file" 2>/dev/null; then
        printf 'TILTVA (a proxy 403-mal elutasította): %s\n' "$url"
    else
        printf 'Nem érhető el: %s\n' "$url"
        head -n 2 "$err_file" | sed 's/^/  /'
    fi
    rm -f "$err_file" "$hdr_file" "$body_file"
    ;;

docs)
    runuser -u "$KIOSK_USER" -- /usr/local/bin/kiosk-docs.sh
    ;;

urls)
    [ -r "$cached" ] || die "Nincs allowlist cache: $cached"
    jq -r '.sites[] | (if .allowed == false then "TILTOTT " else "" end) + "\(.title)\t\(.url)"' "$cached" |
        column -t -s $'\t'
    ;;

set-token)
    printf 'Új GitHub token (fine-grained, Contents: Read). A bevitel nem látszik.\n'
    read -r -s -p 'Token: ' token
    printf '\n'
    [ -n "$token" ] || die "Üres token, nem változtattam."
    printf '%s\n' "$token" >"${GITHUB_TOKEN_FILE}"
    chmod 600 "${GITHUB_TOKEN_FILE}"
    chown root:root "${GITHUB_TOKEN_FILE}"
    printf 'Token mentve: %s\n' "${GITHUB_TOKEN_FILE}"
    printf 'Frissítés: %s update\n' "$0"
    ;;

set-write-token)
    printf 'Új GitHub write token (fine-grained, Contents: Read and write).\n'
    printf 'Ez kell az admin felület GitHubra mentéséhez. A bevitel nem látszik.\n'
    read -r -s -p 'Write token: ' wtoken
    printf '\n'
    [ -n "$wtoken" ] || die "Üres token, nem változtattam."
    printf '%s\n' "$wtoken" >"${GITHUB_WRITE_TOKEN_FILE}"
    chmod 600 "${GITHUB_WRITE_TOKEN_FILE}"
    chown root:root "${GITHUB_WRITE_TOKEN_FILE}"
    systemctl try-restart kiosk-admin-ui.service >/dev/null 2>&1 || true
    printf 'Write token mentve: %s\n' "${GITHUB_WRITE_TOKEN_FILE}"
    ;;

logs)
    lines="${2:-80}"
    journalctl -t kiosk-sync -t kiosk-session -t kiosk-docs -t kiosk-usb \
        -t kiosk-proxy -t kiosk-login-report -t kiosk-update \
        -u kiosk-admin-ui.service -u kiosk-update.service \
        -n "$lines" --no-pager 2>/dev/null || true
    ;;

report)
    shift || true
    exec /usr/local/bin/kiosk-login-report.sh "$@"
    ;;

allow)
    shift || true
    url="${1:-}"
    if [ -z "$url" ]; then
        read -r -p "Engedélyezendő cím (URL vagy domain): " url
    fi
    [ -n "$url" ] || die "Nincs cím."
    host="$(url_host "$url")" || die "Érvénytelen cím: $url"
    local_site_remove_host "$host" >/dev/null 2>&1 || true
    host="$(hidden_add_url "$url")" || die "Érvénytelen cím: $url"
    if ! KIOSK_NO_RELOAD=1 /usr/local/bin/kiosk-render.sh >/dev/null 2>&1; then
        log "WARN" "A render nem sikerült - a szűrő a következő frissítéskor érvényesül."
    fi
    systemctl try-restart kiosk-proxy.service >/dev/null 2>&1 || true
    printf 'Engedélyezve (rejtve, a menüben nem látszik): %s\n' "$host"
    ;;

hidden)
    hidden_hosts | sort -u
    ;;

unallow)
    target="${2:-}"
    [ -n "$target" ] || die "Használat: $0 unallow <host>"
    host="$(url_host "$target")" || host="$target"
    removed=1
    if hidden_remove_host "$host"; then
        removed=0
    fi
    if local_site_remove_host "$host"; then
        removed=0
    fi
    if [ "$removed" = 0 ]; then
        KIOSK_NO_RELOAD=1 /usr/local/bin/kiosk-render.sh >/dev/null 2>&1 || true
        systemctl try-restart kiosk-proxy.service >/dev/null 2>&1 || true
        printf 'Törölve: %s\n' "$host"
    else
        die "Nincs ilyen helyi bejegyzés: $host"
    fi
    ;;

set-pin)
    printf 'Új admin PIN (4-8 számjegy). A bevitel nem látszik.\n'
    read -r -s -p 'PIN: ' pin1 || pin1=""
    printf '\n'
    read -r -s -p 'PIN újra: ' pin2 || pin2=""
    printf '\n'
    [ "$pin1" = "$pin2" ] || die "A két PIN nem egyezik."
    pin_valid_format "$pin1" || die "A PIN 4-8 számjegy lehet."
    pin_store "$pin1" || die "Nem sikerült a PIN mentése."
    systemctl enable kiosk-admin-ui.service >/dev/null 2>&1 || true
    systemctl restart kiosk-admin-ui.service >/dev/null 2>&1 || \
        log "WARN" "Az admin felület szolgáltatása nem indult el."
    printf 'PIN beállítva. A felület: Ctrl+Alt+A a kezdőlapon.\n'
    ;;

doctor)
    echo "== Kiosk diagnosztika =="
    printf 'Felhasználó: %s   Proxy: %s:%s   Kényszerítés: %s\n' \
        "$KIOSK_USER" "127.0.0.1" "$PROXY_PORT" "$ENFORCE_ALLOWLIST"
    printf 'Jelentés: %s   Cél: %s/%s/%s\n\n' \
        "$([ "${REPORT_ENABLED:-0}" = 1 ] && echo bekapcsolva || echo kikapcsolva)" \
        "${REPORT_GITHUB_OWNER:-?}" "${REPORT_GITHUB_REPO:-?}" "${REPORT_PATH:-login-logs}"

    echo "-- tinyproxy --"
    if command -v tinyproxy >/dev/null 2>&1; then
        printf 'telepítve: %s\n' "$(command -v tinyproxy)"
        tinyproxy -v 2>&1 | head -1 || true
    else
        echo "HIÁNYZIK: tinyproxy"
    fi
    printf 'unit: %s\n' "$(systemctl is-active kiosk-proxy.service 2>/dev/null || true)"
    echo "hallgat:"
    ss -ltnp 2>/dev/null | grep -E ":${PROXY_PORT}\b" || echo "  (semmi a ${PROXY_PORT} porton)"

    echo
    echo "-- proxy konfig --"
    [ -r /etc/kiosk/tinyproxy.conf ] && echo "OK  /etc/kiosk/tinyproxy.conf" || echo "HIÁNYZIK: /etc/kiosk/tinyproxy.conf"
    if [ -r /etc/kiosk/proxy-filter ]; then
        printf 'OK  /etc/kiosk/proxy-filter (%s minta)\n' "$(grep -c '^\^' /etc/kiosk/proxy-filter)"
    else
        echo "HIÁNYZIK: /etc/kiosk/proxy-filter"
    fi

    echo
    echo "-- utolsó proxy napló --"
    journalctl -u kiosk-proxy.service -n 20 --no-pager 2>/dev/null | sed 's/^/  /' || true

    echo
    echo "-- Firefox házirend --"
    pol="/etc/firefox-esr/policies/policies.json"
    if [ -r "$pol" ]; then
        printf 'Proxy kulcs: %s\n' "$(jq -r '.policies | if has("Proxy") then .Proxy.HTTPProxy else "nincs (kikapcsolva)" end' "$pol" 2>/dev/null)"
        printf 'Könyvjelzők: %s\n' "$(jq -r '.policies.Bookmarks | length' "$pol" 2>/dev/null)"
    else
        echo "HIÁNYZIK: $pol"
    fi

    echo
    echo "-- tanács --"
    if ! systemctl is-active --quiet kiosk-proxy.service 2>/dev/null; then
        echo "A proxy nem fut. Javítás után:"
        echo "  sudo systemctl reset-failed kiosk-proxy && sudo systemctl restart kiosk-proxy"
        echo "  sudo kiosk-admin.sh render && sudo kiosk-admin.sh restart"
        echo "Ha a konfig hibás, a naplóban 'Unknown keyword' vagy 'Could not parse' látszik."
    elif ! ss -ltn 2>/dev/null | grep -q ":${PROXY_PORT}\b"; then
        echo "A unit fut, de a port nem hallgat. Nézd a naplót fentebb."
    else
        echo "A proxy hallgat a porton. Ha a böngésző mégis hibázik:"
        echo "  sudo kiosk-admin.sh restart"
    fi
    ;;

*)
    usage
    exit 1
    ;;
esac
