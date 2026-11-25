#!/usr/bin/env bash
# =============================================================================
# Dokumentum-feldolgozás füstteszt (nem kell root, nem kell LibreOffice).
# Csak a PDF / videó / kép közvetlen utat és a lista generálást teszteli.
# =============================================================================
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

command -v jq >/dev/null 2>&1 || { echo "HIBA: jq kell." >&2; exit 1; }

mkdir -p "$TMP/www" "$TMP/docs" "$TMP/inbox" "$TMP/run" "$TMP/home"
mkdir -p "$TMP/prefix/lib/kiosk"
for f in common.sh render.sh allowlist.jq policies.jq; do
    ln -s "$ROOT/lib/${f}" "$TMP/prefix/lib/kiosk/${f}"
done

CONF="$TMP/kiosk.conf"
cat >"$CONF" <<EOF
KIOSK_USER=$(id -un)
KIOSK_HOME=$TMP/home
KIOSK_RUN=$TMP/run
START_PAGE=$TMP/www/start.html
DOCS_DIR=$TMP/docs
INBOX_DIR=$TMP/inbox
KIOSK_LIB=$TMP/prefix/lib/kiosk
KIOSK_WEB_DIR=$ROOT/web
EOF

export KIOSK_CONF="$CONF"
export KIOSK_PREFIX="$TMP/prefix"

printf '%%PDF-1.4 teszt\n' >"$TMP/inbox/Szerzodes minta.pdf"
printf '\x00\x00\x00\x18ftypmp42 teszt video\n' >"$TMP/inbox/bemutato.mp4"
printf 'valami\n' >"$TMP/inbox/kep.png"
printf 'nem tamogatott\n' >"$TMP/inbox/valami.xyz"

bash "$ROOT/bin/kiosk-docs.sh" >/dev/null 2>&1 || {
    echo "FAIL: a kiosk-docs.sh hibával lépett ki"
    exit 1
}

IDX="$TMP/docs/index.html"
fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf '  ok   %s\n' "$1"
    else
        printf '  FAIL %s: [%s] != [%s]\n' "$1" "$2" "$3"
        fail=1
    fi
}

check "index létrejött" "$([ -s "$IDX" ] && echo yes)" "yes"
check "PDF a listában" "$(grep -c 'Szerzodes minta' "$IDX")" "1"
check "file:// link" "$(grep -c 'file://' "$IDX")" "3"
check "videó lejátszó" "$(grep -c '<video' "$IDX")" "1"
check "clock.js hivatkozás" "$(grep -c 'src="../clock.js"' "$IDX")" "1"
check "admin hivatkozás" \
    "$(grep -c 'data-admin="http://127.0.0.1:8878/"' "$IDX")" "1"
check "badge PDF" "$(grep -c '>PDF<' "$IDX")" "1"
check "badge VIDEÓ" "$(grep -c '>VIDEÓ<' "$IDX")" "1"
check "inbox kiürült" "$(find "$TMP/inbox" -maxdepth 1 -type f | wc -l)" "0"
check "dokumentumtárban 3 fájl" \
    "$(find "$TMP/docs" -maxdepth 1 -type f ! -name 'index.html' ! -name '.origins' | wc -l)" "3"
check "csak a hibás maradt a processed-ben" \
    "$(find "$TMP/inbox/processed" -type f | wc -l)" "1"
check ".origins nem linkelt" "$(grep -c '.origins' "$IDX")" "0"

echo
if [ "$fail" = 0 ]; then
    echo "DOKUMENTUM TESZT OK"
else
    echo "HIBA a dokumentum tesztben"
    exit 1
fi
