#!/usr/bin/env bash
# =============================================================================
# Helyi füstteszt - nem kell root, nem nyúl a rendszerhez.
# Használat: tests/render-smoke.sh   (jq szükséges)
# =============================================================================
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

command -v jq >/dev/null 2>&1 || {
    echo "HIBA: a teszthez jq kell." >&2
    exit 1
}

mkdir -p "$TMP/www" "$TMP/etc" "$TMP/run" "$TMP/state" "$TMP/policies"

CONF="$TMP/kiosk.conf"
cat >"$CONF" <<EOF
START_PAGE=$TMP/www/start.html
DOCS_DIR=$TMP/www/docs
INBOX_DIR=$TMP/inbox
PROXY_FILTER=$TMP/etc/proxy-filter
PROXY_CONF=$TMP/etc/tinyproxy.conf
KIOSK_ETC=$TMP/etc
KIOSK_POLICY_DIR=$TMP/policies
KIOSK_RUN=$TMP/run
KIOSK_STATE=$TMP/state
KIOSK_LIB=$ROOT/lib
KIOSK_WEB_DIR=$ROOT/web
KIOSK_PROXY_TEMPLATE=$ROOT/proxy/tinyproxy.conf.in
KIOSK_DOWNLOADS=$TMP/Downloads
LOCAL_HIDDEN_FILE=$TMP/etc/hidden-urls.local
LOCAL_SITES_FILE=$TMP/etc/local-sites.local
ADMIN_PIN_FILE=$TMP/etc/admin.pin
ADMIN_UI_PORT=8878
SITE_NAME="Teszt Kiosk"
PROXY_PORT=8877
ENFORCE_ALLOWLIST=1
EOF

export KIOSK_CONF="$CONF"
# shellcheck source=../lib/common.sh
. "$ROOT/lib/common.sh"
export LOG_NAME=test
load_conf
# shellcheck source=../lib/render.sh
. "$ROOT/lib/render.sh"

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf '  ok   %s\n' "$1"
    else
        printf '  FAIL %s: [%s] != [%s]\n' "$1" "$2" "$3"
        fail=1
    fi
}

echo "1) Új séma (examples/allowlist.json)"
jq -f "$ROOT/lib/allowlist.jq" "$ROOT/examples/allowlist.json" >"$TMP/norm-new.json"
if validate_allowlist "$TMP/norm-new.json"; then
    echo "  ok   validáció"
else
    echo "  FAIL validáció"
    fail=1
fi
check "site_count" "$(jq -r '.site_count' "$TMP/norm-new.json")" "15"
check "start_url az élen" "$(jq -r '.sites[0].url' "$TMP/norm-new.json")" \
    "https://www.szerencsejatek.hu/"
jq '.sites = [ .sites[1], .sites[0] ] | .start_url = .sites[1].url' \
    "$ROOT/examples/allowlist.json" >"$TMP/order-input.json"
jq -f "$ROOT/lib/allowlist.jq" "$TMP/order-input.json" >"$TMP/order-norm.json"
check "start_url megtartja a helyét (első)" "$(jq -r '.sites[0].url' "$TMP/order-norm.json")" \
    "https://eto.szerencsejatek.hu/"
check "start_url megtartja a helyét (második)" "$(jq -r '.sites[1].url' "$TMP/order-norm.json")" \
    "https://www.szerencsejatek.hu/"
jq '.sites = [ .sites[1], .sites[0] ] | .start_url = "https://szerencsejatek.hu/"' \
    "$ROOT/examples/allowlist.json" >"$TMP/order-apex-input.json"
jq -f "$ROOT/lib/allowlist.jq" "$TMP/order-apex-input.json" >"$TMP/order-apex.json"
check "host-egyezés nem mozgat" "$(jq -r '.sites[1].url' "$TMP/order-apex.json")" \
    "https://szerencsejatek.hu/"

echo "2) Örökölt séma (a valós repo formátuma)"
jq -f "$ROOT/lib/allowlist.jq" "$ROOT/tests/fixtures/allowlist-legacy.json" \
    >"$TMP/norm-legacy.json"
if validate_allowlist "$TMP/norm-legacy.json"; then
    echo "  ok   validáció"
else
    echo "  FAIL validáció"
    fail=1
fi
check "legacy site_count" "$(jq -r '.site_count' "$TMP/norm-legacy.json")" "15"
check "nincs www duplikátum" \
    "$(jq -r '[.sites[].url] | unique | length' "$TMP/norm-legacy.json")" "15"
check "legacy domain (apex)" \
    "$(jq -r '.domains | index("tippmix.hu") != null' "$TMP/norm-legacy.json")" "true"

echo "3) Rejtett engedélyezés (hidden_urls)"
jq '.hidden_urls = [
    "https://hidden.example.org/secret/page",
    "static2.example.net",
    { "title": "Objektum", "url": "https://obj.example.org/x" }
]' "$ROOT/examples/allowlist.json" >"$TMP/hidden-input.json"
jq -f "$ROOT/lib/allowlist.jq" "$TMP/hidden-input.json" >"$TMP/norm-hidden.json"
if validate_allowlist "$TMP/norm-hidden.json"; then
    echo "  ok   validáció"
else
    echo "  FAIL validáció"
    fail=1
fi
check "rejtett domain a proxyhoz" \
    "$(jq -r '.domains | index("hidden.example.org") != null' "$TMP/norm-hidden.json")" "true"
check "rejtett domain a proxyhoz (2)" \
    "$(jq -r '.domains | index("static2.example.net") != null' "$TMP/norm-hidden.json")" "true"
check "rejtett objektum domainje" \
    "$(jq -r '.domains | index("obj.example.org") != null' "$TMP/norm-hidden.json")" "true"
check "hidden_domains lista" \
    "$(jq -r '.hidden_domains | length' "$TMP/norm-hidden.json")" "3"
check "a menü nem változik" \
    "$(jq -r '.site_count' "$TMP/norm-hidden.json")" "15"
check "nincs rejtett a menüben" \
    "$(jq -r '[.sites[].url] | map(select(test("hidden\\.example\\.org|static2\\.example\\.net|obj\\.example\\.org"))) | length' "$TMP/norm-hidden.json")" "0"

# A generált proxy szűrőben viszont szerepelnie kell a rejtett domainnek.
proxy_filter_save="$PROXY_FILTER"
PROXY_FILTER="$TMP/etc/proxy-filter-hidden"
render_proxy_filter "$TMP/norm-hidden.json" >/dev/null 2>&1
check "rejtett domain a szűrőben" \
    "$(grep -Fc 'hidden\.example\.org' "$TMP/etc/proxy-filter-hidden" 2>/dev/null || true)" "2"
check "rejtett domain a szűrőben (2)" \
    "$(grep -Fc 'static2\.example\.net' "$TMP/etc/proxy-filter-hidden" 2>/dev/null || true)" "2"
check "rejtett objektum a szűrőben" \
    "$(grep -Fc 'obj\.example\.org' "$TMP/etc/proxy-filter-hidden" 2>/dev/null || true)" "2"
if command -v node >/dev/null 2>&1; then
    if node "$ROOT/tests/proxy-filter.test.mjs" "$TMP/etc/proxy-filter-hidden" >/dev/null 2>&1; then
        echo "  ok   rejtett szűrő minták érvényesek"
    else
        echo "  FAIL rejtett szűrő minták"
        fail=1
    fi
fi
PROXY_FILTER="$proxy_filter_save"

echo "3b) Helyi, rejtett engedélyezés (admin felület)"
printf 'https://Local.Example.ORG/valami\n# komment\nbad host\ncdn.local.example.net\n' \
    >"$LOCAL_HIDDEN_FILE"
check "url_host (URL)" "$(url_host 'https://WWW.Example.ORG/ut?x=1')" "example.org"
check "url_host (domain:port)" "$(url_host 'cdn2.example.net:8080')" "cdn2.example.net"
check "url_host (érvénytelen)" "$(url_host 'ftp://nope' || true)" ""
check "helyi rejtett hostok" \
    "$(hidden_hosts | sort -u | tr '\n' ' ')" "cdn.local.example.net local.example.org "
proxy_filter_save="$PROXY_FILTER"
PROXY_FILTER="$TMP/etc/proxy-filter-local"
render_proxy_filter "$TMP/norm-new.json" >/dev/null 2>&1
check "helyi minta a szűrőben" \
    "$(grep -Fc 'local\.example\.org' "$TMP/etc/proxy-filter-local" 2>/dev/null || true)" "2"
check "helyi minta a szűrőben (2)" \
    "$(grep -Fc 'cdn\.local\.example\.net' "$TMP/etc/proxy-filter-local" 2>/dev/null || true)" "2"
check "nincs a menüben" \
    "$(jq -r '[.sites[].url] | map(select(test("local\\.example\\.org"))) | length' "$TMP/norm-new.json")" "0"
PROXY_FILTER="$proxy_filter_save"
rm -f -- "$LOCAL_HIDDEN_FILE"

echo "3c) Helyi látható oldal (főoldal)"
printf 'https://Visible.Example.ORG/oldal\n# komment\nbad host\n' >"$LOCAL_SITES_FILE"
merged="$TMP/norm-visible.json"
if merge_local_sites "$TMP/norm-new.json" >"$merged"; then
    echo "  ok   merge_local_sites"
else
    echo "  FAIL merge_local_sites"
    fail=1
fi
check "site_count +1" "$(jq -r '.site_count' "$merged")" "16"
check "látható oldal a listában" \
    "$(jq -r '[.sites[].url] | index("https://Visible.Example.ORG/oldal") != null' "$merged")" "true"
check "látható domain a proxyhoz" \
    "$(jq -r '.domains | index("visible.example.org") != null' "$merged")" "true"
check "automatikus cím" \
    "$(jq -r '.sites[] | select(.url | test("Visible")) | .title' "$merged")" "visible.example.org"
render_startpage "$merged" "$TMP/www/local-start.html" "Teszt" >/dev/null 2>&1
check "csempe a kezdőlapon" \
    "$(grep -c 'https://Visible.Example.ORG/oldal' "$TMP/www/local-start.html")" "2"
rm -f -- "$LOCAL_SITES_FILE"

echo "3d) Látható, de proxyból tiltott oldal"
jq '.sites = (.sites | map(if (.url | test("eto\\.szerencsejatek\\.hu")) then . + {allowed: false} else . end))' \
    "$ROOT/examples/allowlist.json" >"$TMP/blocked-input.json"
jq -f "$ROOT/lib/allowlist.jq" "$TMP/blocked-input.json" >"$TMP/norm-blocked.json"
if validate_allowlist "$TMP/norm-blocked.json"; then
    echo "  ok   blocked validáció"
else
    echo "  FAIL blocked validáció"
    fail=1
fi
check "blocked site látható" \
    "$(jq -r '.sites[] | select(.url | test("eto\\.szerencsejatek\\.hu")) | .allowed' "$TMP/norm-blocked.json")" "false"
check "blocked domain nincs a proxyban" \
    "$(jq -r '.domains | index("eto.szerencsejatek.hu") == null' "$TMP/norm-blocked.json")" "true"
check "blocked site_count" "$(jq -r '.site_count' "$TMP/norm-blocked.json")" "15"
render_startpage "$TMP/norm-blocked.json" "$TMP/www/blocked-start.html" "Teszt" >/dev/null 2>&1
check "blocked csempe látszik" \
    "$(grep -c 'https://eto.szerencsejatek.hu/' "$TMP/www/blocked-start.html")" "2"
check "blocked csempe jelölve" "$(grep -c 'tile-blocked' "$TMP/www/blocked-start.html")" "1"
check "blocked PIN jelvény" "$(grep -c 'tile-lock' "$TMP/www/blocked-start.html")" "1"
render_policies "$TMP/norm-blocked.json" >/dev/null 2>&1
check "blocked könyvjelző PIN-oldalra mutat" \
    "$(jq -r '[.policies.Bookmarks[] | select(.URL | contains("unlock?target="))] | length' \
        "$TMP/policies/policies.json")" "1"
proxy_filter_save="$PROXY_FILTER"
PROXY_FILTER="$TMP/etc/proxy-filter-blocked"
render_proxy_filter "$TMP/norm-blocked.json" >/dev/null 2>&1
check "blocked domain nincs a szűrőben" \
    "$(grep -Fc 'eto\.szerencsejatek\.hu' "$TMP/etc/proxy-filter-blocked" 2>/dev/null || true)" "0"
PROXY_FILTER="$proxy_filter_save"

echo "4) Render"
cp "$TMP/norm-new.json" "$TMP/state/allowlist.json"
if render_all "$TMP/norm-new.json" >/dev/null 2>&1; then
    echo "  ok   render_all"
else
    echo "  FAIL render_all"
    fail=1
fi
check "programverzió a kezdőlap láblécében" \
    "$(grep -o 'id="kiosk-version">verzió [^<]*' "$START_PAGE" | sed 's/.*verzió //')" \
    "$(tr -d '[:space:]' <"$ROOT/VERSION")"

POL="$TMP/policies/policies.json"
check "policies létrejött" "$([ -s "$POL" ] && echo yes)" "yes"
check "könyvjelzők száma" "$(jq -r '.policies.Bookmarks | length' "$POL")" "16"
check "mappában lévő könyvjelzők" \
    "$(jq -r '[.policies.Bookmarks[] | select(.Folder == "Engedélyezett oldalak")] | length' "$POL")" "15"
check "home könyvjelző" "$(jq -r '.policies.Bookmarks[0].Title' "$POL")" "⌂ Kezdőlap"
check "home URL" \
    "$(jq -r '.policies.Bookmarks[0].URL | startswith("file://")' "$POL")" "true"
check "proxy mód" "$(jq -r '.policies.Proxy.Mode' "$POL")" "manual"
check "localhost bypass" \
    "$(jq -r '.policies.Preferences["network.proxy.no_proxies_on"] | contains("127.0.0.1")' "$POL")" "true"
check "homepage locked" "$(jq -r '.policies.Homepage.Locked' "$POL")" "true"
check "könyvjelzősáv látszik" "$(jq -r '.policies.DisplayBookmarksToolbar' "$POL")" "true"
check "userChrome engedélyezve" \
    "$(jq -r '.policies.Preferences["toolkit.legacyUserProfileCustomizations.stylesheets"]' "$POL")" "true"
check "magyar Firefox UI" \
    "$(jq -r '.policies.Preferences["intl.locale.requested"]' "$POL")" "hu"
check "magyar Accept-Language" \
    "$(jq -r '.policies.Preferences["intl.accept_languages"]' "$POL")" "hu-HU, hu, en-US, en"
check "billentyűzet XKB layout" \
    "$(grep -Fc 'XKB_DEFAULT_LAYOUT="${KEYBOARD_LAYOUT:-hu}"' "$ROOT/bin/kiosk-session.sh")" "1"

check "kezdőlap tile-ok" "$(grep -c '<a class="tile' "$TMP/www/start.html")" "16"
check "címbeviteli mező" "$(grep -c 'id="address"' "$TMP/www/start.html")" "1"
check "PIN gomb" "$(grep -c 'id="unlock-btn"' "$TMP/www/start.html")" "1"
check "Zár gomb" "$(grep -c 'id="lock-btn"' "$TMP/www/start.html")" "1"
check "PIN modal" "$(grep -c 'id="unlock-frame"' "$TMP/www/start.html")" "1"
check "stylesheet másolva" "$([ -s "$TMP/www/style.css" ] && echo yes)" "yes"
check "clock.js másolva" "$([ -s "$TMP/www/clock.js" ] && echo yes)" "yes"
check "admin Ctrl+Alt+A" "$(grep -Fc '!event.shiftKey' "$ROOT/web/clock.js")" "1"
check "admin KeyA" "$(grep -Fc "event.code === 'KeyA'" "$ROOT/web/clock.js")" "1"
check "kezdőlap clock.js hivatkozás" \
    "$(grep -c 'src="clock.js"' "$TMP/www/start.html")" "1"
check "kezdőlap admin hivatkozás" \
    "$(grep -c 'data-admin="http://127.0.0.1:8878/"' "$TMP/www/start.html")" "1"

domains="$(jq -r '.domains | length' "$TMP/norm-new.json")"
check "proxy minta száma" "$(grep -c '^\^' "$TMP/etc/proxy-filter")" "$((domains * 2))"
check "proxy conf port" "$(grep -c '^Port 8877' "$TMP/etc/tinyproxy.conf")" "1"
check "proxy default deny" "$(grep -c '^FilterDefaultDeny Yes' "$TMP/etc/tinyproxy.conf")" "1"
check "proxy FilterType ere" "$(grep -c '^FilterType ere' "$TMP/etc/tinyproxy.conf")" "1"
check "magyar proxy hibaoldal" \
    "$(grep -c '^DefaultErrorFile' "$TMP/etc/tinyproxy.conf")" "1"
check "hibaoldal fájl" "$([ -s "$ROOT/proxy/error.html" ] && echo yes)" "yes"

echo "1b) Felbontás mező"
jq '.resolution = "1366x768"' "$ROOT/examples/allowlist.json" >"$TMP/res-input.json"
jq -f "$ROOT/lib/allowlist.jq" "$TMP/res-input.json" >"$TMP/res-norm.json"
check "resolution átvezetve" "$(jq -r '.resolution' "$TMP/res-norm.json")" "1366x768"
if validate_allowlist "$TMP/res-norm.json"; then
    echo "  ok   resolution validáció"
else
    echo "  FAIL resolution validáció"
    fail=1
fi
jq '.resolution = "fullhd"' "$ROOT/examples/allowlist.json" >"$TMP/res-bad-input.json"
jq -f "$ROOT/lib/allowlist.jq" "$TMP/res-bad-input.json" >"$TMP/res-bad.json"
if validate_allowlist "$TMP/res-bad.json"; then
    echo "  FAIL a hibás felbontást el kellett volna utasítani"
    fail=1
else
    echo "  ok   hibás felbontás elutasítva"
fi
check "felbontás a sessionben" \
    "$(grep -Fc 'kiosk-set-resolution.sh' "$ROOT/bin/kiosk-session.sh")" "1"
# A tinyproxy a sor belsejében lévő escapeletlen '#'-nél is megjegyzést kezd,
# ezért a mintákban nem lehet '#': a levágott sor érvénytelen regex lenne.
check "proxy mintában nincs '#'" \
    "$(awk '/^\^/ && index($0, "#") { n++ } END { print n + 0 }' "$TMP/etc/proxy-filter")" "0"

# A tinyproxy 1.11 már nem ismeri ezeket - ha benne vannak, el sem indul.
for bad in StartServers MinSpareServers MaxSpareServers MaxRequestsPerChild FilterURLs; do
    check "nincs ${bad} a proxy konfigban" \
        "$(grep -c "^${bad}" "$TMP/etc/tinyproxy.conf")" "0"
done

echo "4b) PIN-es proxy bypass"
bypass_file="${KIOSK_BYPASS_FILE:-$TMP/run/proxy-bypass}"
printf '%s\n' "$(( $(date +%s) + 120 ))" >"$bypass_file"
render_proxy_conf >/dev/null 2>&1
check "bypass: nincs Filter" "$(grep -c '^Filter' "$PROXY_CONF" 2>/dev/null || true)" "0"
check "bypass: nincs FilterDefaultDeny" \
    "$(grep -c 'FilterDefaultDeny' "$PROXY_CONF" 2>/dev/null || true)" "0"
printf '%s\n' "$(( $(date +%s) - 10 ))" >"$bypass_file"
render_proxy_conf >/dev/null 2>&1
check "lejárt bypass: Filter vissza" "$(grep -c '^Filter "' "$PROXY_CONF")" "1"
check "lejárt bypass: fájl törölve" "$([ -e "$bypass_file" ] && echo yes || echo no)" "no"

echo "5) Proxy kikapcsolva (ENFORCE_ALLOWLIST=0)"
ENFORCE_ALLOWLIST=0 render_policies "$TMP/norm-new.json" >/dev/null 2>&1
check "nincs Proxy kulcs" "$(jq -r '.policies | has("Proxy")' "$POL")" "false"
ENFORCE_ALLOWLIST=1 render_policies "$TMP/norm-new.json" >/dev/null 2>&1

echo "6) Proxy szűrő minták (Node)"
if command -v node >/dev/null 2>&1; then
    if node "$ROOT/tests/proxy-filter.test.mjs" "$TMP/etc/proxy-filter"; then
        echo "  ok   proxy szűrő"
    else
        echo "  FAIL proxy szűrő"
        fail=1
    fi
else
    echo "  skip (nincs node)"
fi

echo "7) Világos téma kontrasztja (Node)"
if command -v node >/dev/null 2>&1; then
    if node "$ROOT/tests/contrast.test.mjs" "$ROOT/web/style.css"; then
        echo "  ok   kontraszt"
    else
        echo "  FAIL kontraszt"
        fail=1
    fi
else
    echo "  skip (nincs node)"
fi

echo "8) Dátum és névnap (Node)"
if command -v node >/dev/null 2>&1; then
    if node "$ROOT/tests/clock.test.mjs"; then
        echo "  ok   dátum/névnap"
    else
        echo "  FAIL dátum/névnap"
        fail=1
    fi
else
    echo "  skip (nincs node)"
fi

echo
if [ "$fail" = 0 ]; then
    echo "MINDEN TESZT OK"
else
    echo "HIBA a tesztekben"
    exit 1
fi
