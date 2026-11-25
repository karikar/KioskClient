#!/usr/bin/env bash
# =============================================================================
# Belépéskori jelentés füsttesztje - nem kell root, nem hálózik.
#
# A --dry-run módban a szkript összeállítja a naplót és kiírja a célútvonalat,
# de nem tölt fel semmit. Ezt ellenőrizzük itt.
#
# Használat: tests/report-smoke.sh
# =============================================================================
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

PREFIX="$TMP/prefix"
mkdir -p "$PREFIX/lib/kiosk" "$TMP/etc" "$TMP/state"
cp "$ROOT/lib/common.sh" "$PREFIX/lib/kiosk/common.sh"

conf="$TMP/kiosk.conf"
cat >"$conf" <<EOF
KIOSK_ETC=$TMP/etc
KIOSK_STATE=$TMP/state
REPORT_ENABLED=1
REPORT_GITHUB_OWNER=teszt
REPORT_GITHUB_REPO=repo
REPORT_GITHUB_REF=main
REPORT_PATH=login-logs
REPORT_TOKEN_FILE=$TMP/etc/report.token
REPORT_LOG_LINES=5
EOF
printf 'dummy-token\n' >"$TMP/etc/report.token"

fail=0
check() {
    local name="$1" file="$2" pattern="$3"
    if grep -Eq -- "$pattern" "$file"; then
        printf '  ok   %s\n' "$name"
    else
        printf '  FAIL %s (nincs: %s)\n' "$name" "$pattern"
        fail=1
    fi
}

run_report() {
    local out="$1" conf_file="$2"
    shift 2
    KIOSK_PREFIX="$PREFIX" KIOSK_CONF="$conf_file" KIOSK_REPORT_IP=203.0.113.7 \
        bash "$ROOT/bin/kiosk-login-report.sh" --dry-run "$@" >"$out" 2>&1
}

echo "1) Jelentés összeállítása (--dry-run)"
out="$TMP/out1.txt"
run_report "$out" "$conf" --user kiosk --service login --tty tty1

check "időpont (ISO 8601)" "$out" '^timestamp: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$'
check "nyilvános IP" "$out" '^public_ip: 203\.0\.113\.7$'
check "hostnév" "$out" '^hostname: .+'
check "felhasználó" "$out" '^user: kiosk$'
check "szolgáltatás" "$out" '^service: login$'
check "napló szakasz" "$out" '^# --- napló'
check "célútvonal" "$out" "Fájl    : login-logs/.*/[0-9]{6}-kiosk\\.log$"

if [ -s "$TMP/state/last-login-report.log" ]; then
    printf '  ok   helyi másolat (last-login-report.log)\n'
    check "másolatban is ott az IP" "$TMP/state/last-login-report.log" '^public_ip: 203\.0\.113\.7$'
else
    printf '  FAIL nincs helyi másolat: state/last-login-report.log\n'
    fail=1
fi

echo "2) Felhasználónév biztonságos a fájlnévben"
out2="$TMP/out2.txt"
run_report "$out2" "$conf" --user 'a b/c' --service sshd --tty pts/0
check "sanitizált fájlnév" "$out2" "Fájl    : login-logs/.*/[0-9]{6}-a-b-c\\.log$"

echo "3) Feltöltés (mock curl, hálózat nélkül)"
if command -v jq >/dev/null 2>&1 && command -v base64 >/dev/null 2>&1; then
    mockdir="$TMP/mock"
    mkdir -p "$mockdir/bin"
    cat >"$mockdir/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""
data=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --data-binary) data="${2#@}"; shift 2 ;;
        -o) out="$2"; shift 2 ;;
        --config | --max-time | -X | -H | --proto | -w | --retry | --retry-delay) shift 2 ;;
        *) shift ;;
    esac
done
[ -n "$data" ] && cp -- "$data" "${MOCK_DIR}/payload.json"
[ -n "$out" ] && printf '{"content":{"path":"ok"}}' >"$out"
printf '201'
SH
    chmod +x "$mockdir/bin/curl"

    out3="$TMP/out3.txt"
    MOCK_DIR="$mockdir" PATH="$mockdir/bin:$PATH" \
        KIOSK_PREFIX="$PREFIX" KIOSK_CONF="$conf" KIOSK_REPORT_IP=203.0.113.7 \
        bash "$ROOT/bin/kiosk-login-report.sh" --user kiosk --service login \
        >"$out3" 2>&1 || true

    check "feltöltés sikeres" "$out3" 'Jelentés feltöltve'
    check "commit üzenet" "$mockdir/payload.json" '"message": "Login report: .*203\.0\.113\.7'
    check "branch" "$mockdir/payload.json" '"branch": "main"'

    if [ -s "$mockdir/payload.json" ]; then
        jq -r '.content' "$mockdir/payload.json" | base64 -d >"$TMP/decoded.log" 2>/dev/null || true
        check "feltöltött naplóban IP" "$TMP/decoded.log" '^public_ip: 203\.0\.113\.7$'
        check "feltöltött naplóban időpont" "$TMP/decoded.log" '^timestamp: '
    else
        printf '  FAIL nincs payload.json (a mock curl nem kapott kérést)\n'
        fail=1
    fi
else
    echo "  skip (nincs jq/base64)"
fi

echo "4) Kikapcsolt jelentés"
conf_off="$TMP/kiosk-off.conf"
sed 's/^REPORT_ENABLED=.*/REPORT_ENABLED=0/' "$conf" >"$conf_off"
out4="$TMP/out4.txt"
KIOSK_PREFIX="$PREFIX" KIOSK_CONF="$conf_off" \
    bash "$ROOT/bin/kiosk-login-report.sh" --dry-run >"$out4" 2>&1
check "kikapcsolva jelzés" "$out4" 'ki van kapcsolva'

echo
if [ "$fail" = 0 ]; then
    echo "MINDEN JELENTÉS-TESZT OK"
else
    echo "HIBA a jelentés tesztjeiben"
    exit 1
fi
