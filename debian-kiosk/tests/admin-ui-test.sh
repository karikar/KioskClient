#!/usr/bin/env bash
# =============================================================================
# A helyi admin UI (kiosk-admin-ui.py) integrációs tesztje.
# Nem kell root és nem hívja a GitHubot: teszt config/save fájlokkal fut.
# =============================================================================
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
cleanup() {
    if [ -n "${SERVER_PID:-}" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf -- "$TMP"
}
trap cleanup EXIT

if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    echo "SKIP: python3 és curl kell a teszthez."
    exit 0
fi

PORT=$((18000 + ($$ % 1000)))
PIN_FILE="$TMP/admin.pin"
CONFIG="$TMP/config.json"
SAVED="$TMP/saved.json"
BYPASS="$TMP/bypass"
mkdir -p "$TMP/docs" "$TMP/inbox"

SALT="testsalt"
HASH="$(python3 - "$SALT" <<'PY'
import hashlib
import sys
print(hashlib.sha256((sys.argv[1] + "1234").encode()).hexdigest())
PY
)"
printf 'sha256:%s:%s\n' "$SALT" "$HASH" >"$PIN_FILE"

cat >"$CONFIG" <<'JSON'
{
  "start_url": "https://www.szerencsejatek.hu/",
  "sites": [
    { "title": "Szerencsejáték", "url": "https://www.szerencsejatek.hu/" },
    { "title": "TippMix", "url": "https://www.tippmix.hu/" }
  ],
  "extra_domains": ["cdn.example.org"],
  "hidden_urls": [
    "https://hidden.example.org/x",
    { "title": "OTR", "url": "https://v2.otr.hu/" }
  ],
  "refresh_interval_seconds": 300,
  "resolution": "1366x768"
}
JSON

printf '1.2.3\n' >"$TMP/VERSION"
printf 'checked=2026-11-25 10:00:00\ninstalled=1.2.3\nlatest=1.3.0\nresult=available\n' \
    >"$TMP/update-status"

ADMIN_UI_PORT="$PORT" \
ADMIN_PIN_FILE="$PIN_FILE" \
ADMIN_HTML_FILE="$ROOT/web/admin.html" \
UNLOCK_HTML_FILE="$ROOT/web/unlock.html" \
THEME_JS_FILE="$ROOT/web/theme.js" \
KIOSK_THEME_FILE="$TMP/theme" \
KIOSK_VERSION_FILE="$TMP/VERSION" \
KIOSK_UPDATE_STATUS_FILE="$TMP/update-status" \
KIOSK_BYPASS_FILE="$BYPASS" \
ADMIN_BYPASS_MINUTES=15 \
KIOSK_ADMIN_TEST_CONFIG="$CONFIG" \
KIOSK_ADMIN_TEST_SAVE="$SAVED" \
KIOSK_ADMIN_TEST_DISCOVER_FILE="$ROOT/tests/fixtures/discover.html" \
KIOSK_DOCS_DIR="$TMP/docs" \
KIOSK_INBOX_DIR="$TMP/inbox" \
KIOSK_ADMIN_TEST_SKIP_DOCS=1 \
KIOSK_ADMIN_TEST_SKIP_POWER=1 \
KIOSK_ADMIN_TEST_SKIP_UPDATE=1 \
KIOSK_ADMIN_TEST_UPDATE_CHECK_RC=10 \
KIOSK_ADMIN_TEST_SKIP_SYNC=1 \
KIOSK_ADMIN_TEST_SKIP_RENDER=1 \
    python3 "$ROOT/bin/kiosk-admin-ui.py" >"$TMP/server.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 50); do
    if curl -s -o /dev/null "http://127.0.0.1:${PORT}/"; then
        break
    fi
    sleep 0.1
done

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf '  ok   %s\n' "$1"
    else
        printf '  FAIL %s: [%s] != [%s]\n' "$1" "$2" "$3"
        fail=1
    fi
}

post_file() {
    curl -s -o "$TMP/resp.json" -w '%{http_code}' \
        -X POST \
        -H 'Content-Type: application/json' \
        -H 'X-Kiosk-Admin: 1' \
        --data-binary "@$2" \
        "http://127.0.0.1:${PORT}$1"
}

json() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"
}

echo "0) Admin oldal kiszolgálása"
code="$(curl -s -o "$TMP/admin.html" -w '%{http_code}' "http://127.0.0.1:${PORT}/")"
check "HTTP 200" "$code" "200"
check "PIN kapu" "$(grep -c 'id="gate"' "$TMP/admin.html")" "1"
check "szerkesztő" "$(grep -c 'id="sites"' "$TMP/admin.html")" "1"
check "power gomb" "$(grep -c 'id="power-btn"' "$TMP/admin.html")" "1"

echo "1) PIN ellenőrzés"
cat >"$TMP/auth-bad.json" <<'JSON'
{"pin":"0000"}
JSON
code="$(post_file /auth "$TMP/auth-bad.json")"
check "rossz PIN 403" "$code" "403"
cat >"$TMP/auth-ok.json" <<'JSON'
{"pin":"1234"}
JSON
code="$(post_file /auth "$TMP/auth-ok.json")"
check "jó PIN 200" "$code" "200"
check "ok válasz" "$(json "$TMP/resp.json" ok)" "True"

echo "2) Konfiguráció betöltése"
code="$(post_file /config "$TMP/auth-ok.json")"
check "HTTP 200" "$code" "200"
check "sites darab" "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["config"]["sites"]))' "$TMP/resp.json")" "2"
check "meta owner" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["meta"]["owner"])' "$TMP/resp.json")" "karikar"
check "resolution" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["config"]["resolution"])' "$TMP/resp.json")" "1366x768"

echo "3) Mentés (teszt GitHub helyett fájlba)"
cat >"$TMP/save.json" <<'JSON'
{
  "pin": "1234",
  "config": {
    "start_url": "https://uj.example.org/",
    "sites": [
      { "title": "Új oldal", "url": "https://uj.example.org/", "allowed": false }
    ],
    "extra_domains": ["cdn.uj.hu"],
    "hidden_urls": [
      { "title": "Rejtett", "url": "https://rejtett.example.org/" },
      "https://raw.example.org/"
    ],
    "refresh_interval_seconds": 600,
    "resolution": "1920x1080"
  }
}
JSON
code="$(post_file /save "$TMP/save.json")"
check "HTTP 200" "$code" "200"
check "mentett start_url" "$(jq -r '.start_url' "$SAVED")" "https://uj.example.org/"
check "mentett sites" "$(jq -r '.sites | length' "$SAVED")" "1"
check "mentett tiltott oldal" "$(jq -r '.sites[0].allowed' "$SAVED")" "false"
check "mentett extra" "$(jq -r '.extra_domains[0]' "$SAVED")" "cdn.uj.hu"
check "mentett rejtett objektum" "$(jq -r '.hidden_urls[0].title' "$SAVED")" "Rejtett"
check "mentett rejtett string" "$(jq -r '.hidden_urls[1]' "$SAVED")" "https://raw.example.org/"
check "mentett refresh" "$(jq -r '.refresh_interval_seconds' "$SAVED")" "600"
check "mentett resolution" "$(jq -r '.resolution' "$SAVED")" "1920x1080"

echo "3b) Visszaolvasás a mentés után"
code="$(post_file /config "$TMP/auth-ok.json")"
check "HTTP 200" "$code" "200"
check "új start_url" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["config"]["start_url"])' "$TMP/resp.json")" "https://uj.example.org/"

echo "4) Érvénytelen mentés elutasítva"
cat >"$TMP/save-bad.json" <<'JSON'
{
  "pin": "1234",
  "config": {
    "start_url": "ftp://nope.example.org/",
    "sites": [{ "title": "X", "url": "https://x.example.org/" }],
    "extra_domains": [],
    "hidden_urls": [],
    "refresh_interval_seconds": 300,
    "resolution": ""
  }
}
JSON
code="$(post_file /save "$TMP/save-bad.json")"
check "HTTP 400" "$code" "400"
check "a mentett fájl nem változott" "$(jq -r '.start_url' "$SAVED")" "https://uj.example.org/"

echo "4b) Duplikáció és domain-ütközés"
cat >"$TMP/save-dup.json" <<'JSON'
{
  "pin": "1234",
  "config": {
    "start_url": "https://uj.example.org/",
    "sites": [
      { "title": "A", "url": "https://dup.example.org/" },
      { "title": "B", "url": "https://dup.example.org/" }
    ],
    "extra_domains": [],
    "hidden_urls": [],
    "refresh_interval_seconds": 300,
    "resolution": ""
  }
}
JSON
code="$(post_file /save "$TMP/save-dup.json")"
check "duplikált webcím 400" "$code" "400"

cat >"$TMP/save-conflict.json" <<'JSON'
{
  "pin": "1234",
  "config": {
    "start_url": "https://uj.example.org/",
    "sites": [
      { "title": "Tiltott", "url": "https://blocked.example.org/", "allowed": false }
    ],
    "extra_domains": ["example.org"],
    "hidden_urls": [],
    "refresh_interval_seconds": 300,
    "resolution": ""
  }
}
JSON
code="$(post_file /save "$TMP/save-conflict.json")"
check "domain-ütközés 400" "$code" "400"

echo "5) Kikapcsolás / újraindítás (teszt módban nem hajtja végre)"
cat >"$TMP/power.json" <<'JSON'
{"pin":"1234","action":"reboot"}
JSON
code="$(post_file /power "$TMP/power.json")"
check "reboot 200" "$code" "200"
cat >"$TMP/power-bad.json" <<'JSON'
{"pin":"1234","action":"format"}
JSON
code="$(post_file /power "$TMP/power-bad.json")"
check "ismeretlen művelet 400" "$code" "400"

echo "5a) Programfrissítés gomb (/update, teszt módban nem indít)"
printf '{"pin":"1234","action":"check"}\n' >"$TMP/upd-check.json"
code="$(post_file /update "$TMP/upd-check.json")"
check "frissítés keresése 200" "$code" "200"
check "új verzió jelezve" "$(json "$TMP/resp.json" available)" "True"
check "telepített verzió a válaszban" "$(json "$TMP/resp.json" version)" "1.2.3"
printf '{"pin":"1234","action":"start"}\n' >"$TMP/upd-start.json"
code="$(post_file /update "$TMP/upd-start.json")"
check "frissítés indítása 200" "$code" "200"
check "frissítés elindult" "$(json "$TMP/resp.json" started)" "True"
printf '{"pin":"9999","action":"start"}\n' >"$TMP/upd-badpin.json"
code="$(post_file /update "$TMP/upd-badpin.json")"
check "frissítés rossz PIN-nel 403" "$code" "403"
printf '{"pin":"1234","action":"rm"}\n' >"$TMP/upd-bad.json"
code="$(post_file /update "$TMP/upd-bad.json")"
check "ismeretlen frissítési művelet elutasítva" "$code" "500"
check "frissítés gombok az admin oldalon" \
    "$(grep -cE 'id="update-(check|start)"' "$ROOT/web/admin.html")" "2"

echo "5b) PIN-es proxy feloldás"
code="$(curl -s -o "$TMP/unlock.html" -w '%{http_code}' "http://127.0.0.1:${PORT}/unlock")"
check "feloldó oldal 200" "$code" "200"
check "PIN mező" "$(grep -c 'id="pin"' "$TMP/unlock.html")" "1"
check "visszazárás gomb" "$(grep -c 'id="lock"' "$TMP/unlock.html")" "1"

cat >"$TMP/unlock-bad.json" <<'JSON'
{"pin":"0000"}
JSON
code="$(post_file /unlock "$TMP/unlock-bad.json")"
check "rossz PIN 403" "$code" "403"

cat >"$TMP/unlock-ok.json" <<'JSON'
{"pin":"1234"}
JSON
code="$(post_file /unlock "$TMP/unlock-ok.json")"
check "feloldás 200" "$code" "200"
check "aktív" "$(json "$TMP/resp.json" active)" "True"
check "bypass fájl létrejött" "$([ -s "$BYPASS" ] && echo yes)" "yes"

curl -s -o "$TMP/status.json" "http://127.0.0.1:${PORT}/unlock-status"
check "státusz aktív" "$(json "$TMP/status.json" active)" "True"

code="$(post_file /lock "$TMP/unlock-ok.json")"
check "visszazárás 200" "$code" "200"
check "bypass fájl törölve" "$([ -e "$BYPASS" ] && echo yes || echo no)" "no"
curl -s -o "$TMP/status2.json" "http://127.0.0.1:${PORT}/unlock-status"
check "státusz inaktív" "$(json "$TMP/status2.json" active)" "False"

echo "5b) Programverzió (/version)"
code="$(curl -s -o "$TMP/version.json" -w '%{http_code}' "http://127.0.0.1:${PORT}/version")"
check "verzió 200" "$code" "200"
check "telepített verzió" "$(json "$TMP/version.json" version)" "1.2.3"
check "legújabb kiadás" "$(json "$TMP/version.json" latest)" "1.3.0"
check "frissítés állapota" "$(json "$TMP/version.json" result)" "available"
check "admin oldal mutatja a verziót" \
    "$(grep -c 'id="version-info"' "$ROOT/web/admin.html")" "1"

echo "5c) Visszazárás PIN nélkül"
printf '{}\n' >"$TMP/lock-empty.json"
code="$(post_file /lock "$TMP/lock-empty.json")"
check "lock PIN nélkül 200" "$code" "200"

echo "5d) Külső domainek keresése"
cat >"$TMP/discover.json" <<'JSON'
{"pin":"1234","url":"https://www.example.org/page"}
JSON
code="$(post_file /discover "$TMP/discover.json")"
check "discover HTTP 200" "$code" "200"
check "saját domain kizárva" \
    "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(any(x["domain"] in ("www.example.org","example.org") for x in d["domains"]))' "$TMP/resp.json")" "False"
check "külső domainek" \
    "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["domains"]))' "$TMP/resp.json")" "6"
check "partner link kihagyva" \
    "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(any(x["domain"] == "partner.example.com" for x in d["domains"]))' "$TMP/resp.json")" "False"
check "képek domainje" \
    "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print([x["count"] for x in d["domains"] if x["domain"] == "images.example.net"][0])' "$TMP/resp.json")" "3"

cat >"$TMP/discover-bad.json" <<'JSON'
{"pin":"1234","url":"ftp://nope"}
JSON
code="$(post_file /discover "$TMP/discover-bad.json")"
check "discover érvénytelen 400" "$code" "400"

echo "5e) Helyi dokumentumok"
cat >"$TMP/docs-list.json" <<'JSON'
{"pin":"1234"}
JSON
code="$(post_file /docs/list "$TMP/docs-list.json")"
check "docs lista 200" "$code" "200"
check "docs lista üres" "$(jq -r '.docs | length' "$TMP/resp.json")" "0"

printf 'helló dokumentum\n' >"$TMP/upload.txt"
code="$(curl -s -o "$TMP/upload-resp.json" -w '%{http_code}' \
    -X POST \
    -H 'X-Kiosk-Admin: 1' \
    -H 'X-Kiosk-PIN: 1234' \
    -H 'X-Kiosk-Filename: upload.txt' \
    -H 'Content-Type: application/octet-stream' \
    --data-binary "@$TMP/upload.txt" \
    "http://127.0.0.1:${PORT}/docs/upload")"
check "docs feltöltés 200" "$code" "200"
check "fájl az inboxban" "$([ -f "$TMP/inbox/upload.txt" ] && echo yes || echo no)" "yes"

cat >"$TMP/inbox-list.json" <<'JSON'
{"pin":"1234"}
JSON
code="$(post_file /docs/inbox "$TMP/inbox-list.json")"
check "inbox lista 200" "$code" "200"
check "inbox lista egy elem" "$(jq -r '.inbox | length' "$TMP/resp.json")" "1"

code="$(post_file /docs/process "$TMP/inbox-list.json")"
check "inbox feldolgozás 200" "$code" "200"

cat >"$TMP/inbox-del.json" <<'JSON'
{"pin":"1234","name":"upload.txt"}
JSON
code="$(post_file /docs/inbox/delete "$TMP/inbox-del.json")"
check "inbox törlés 200" "$code" "200"
check "inbox törölve" "$([ -f "$TMP/inbox/upload.txt" ] && echo yes || echo no)" "no"
check "inbox lista üres" "$(jq -r '.inbox | length' "$TMP/resp.json")" "0"

printf '%%PDF-1.4 teszt\n' >"$TMP/docs/test.pdf"
code="$(post_file /docs/list "$TMP/docs-list.json")"
check "docs lista egy elem" "$(jq -r '.docs | length' "$TMP/resp.json")" "1"
cat >"$TMP/docs-del.json" <<'JSON'
{"pin":"1234","name":"test.pdf"}
JSON
code="$(post_file /docs/delete "$TMP/docs-del.json")"
check "docs törlés 200" "$code" "200"
check "docs fájl törölve" "$([ -f "$TMP/docs/test.pdf" ] && echo yes || echo no)" "no"
check "docs lista újra üres" "$(jq -r '.docs | length' "$TMP/resp.json")" "0"

echo "5f) Világos/sötét téma"
code="$(curl -s -o "$TMP/theme.json" -w '%{http_code}' "http://127.0.0.1:${PORT}/theme")"
check "téma GET 200" "$code" "200"
check "alap téma világos" "$(jq -r '.theme' "$TMP/theme.json")" "light"
printf '{"theme":"dark"}\n' >"$TMP/theme-dark.json"
code="$(curl -s -o "$TMP/theme.json" -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' \
    --data-binary "@$TMP/theme-dark.json" \
    "http://127.0.0.1:${PORT}/theme")"
check "téma POST 200" "$code" "200"
check "téma sötét mentve" "$(jq -r '.theme' "$TMP/theme.json")" "dark"
printf '{"theme":"light"}\n' >"$TMP/theme-light.json"
code="$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' \
    --data-binary "@$TMP/theme-light.json" \
    "http://127.0.0.1:${PORT}/theme")"
check "téma vissza világos" "$code" "200"
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/theme.js")"
check "téma script 200" "$code" "200"

echo "6) Fejléc nélküli kérés elutasítva"
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' --data-binary "@$TMP/auth-ok.json" \
    "http://127.0.0.1:${PORT}/config")"
check "HTTP 403" "$code" "403"

echo "7) URL-feldolgozás (--check-url)"
check "nagybetű/útvonal" \
    "$(python3 "$ROOT/bin/kiosk-admin-ui.py" --check-url 'https://WWW.Example.ORG/ut?x=1')" \
    "example.org"
if python3 "$ROOT/bin/kiosk-admin-ui.py" --check-url 'ftp://nope' >/dev/null 2>&1; then
    printf '  FAIL az ftp:// címet el kellett volna utasítani\n'
    fail=1
else
    printf '  ok   ftp:// elutasítva\n'
fi

echo
if [ "$fail" = 0 ]; then
    echo "ADMIN UI TESZT OK"
else
    echo "HIBA az admin UI tesztben"
    exit 1
fi
