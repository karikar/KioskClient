#!/usr/bin/env bash
# =============================================================================
# Önfrissítő füstteszt - nem kell root, nem hálózik.
#
# Egy file:// alapú "GitHub API"-t épít (releases/latest.json + csatolmányok),
# és a kiosk-update.sh --check / --dry-run ágait ellenőrzi:
#   verzió-összehasonlítás, csomag letöltés, SHA-256, VERSION egyezés,
#   hiányzó csatolmány, pre-release kihagyás.
#
# Használat: tests/update-smoke.sh
# =============================================================================
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

PREFIX="$TMP/prefix"
mkdir -p "$PREFIX/lib/kiosk" "$TMP/etc" "$TMP/state" "$TMP/run" "$TMP/dist"
cp "$ROOT/lib/common.sh" "$PREFIX/lib/kiosk/common.sh"

fail=0
ok() { printf '  ok   %s\n' "$1"; }
bad() {
    printf '  FAIL %s\n' "$1"
    fail=1
}

# --- 1. verzió függvények ---------------------------------------------------
echo "1) version_gt / version_normalize"
(
    # shellcheck source=../lib/common.sh
    . "$PREFIX/lib/kiosk/common.sh"
    t() {
        if version_gt "$1" "$2"; then r=1; else r=0; fi
        [ "$r" = "$3" ] && ok "version_gt $1 $2 = $3" || bad "version_gt $1 $2 != $3"
    }
    t 1.1.0 1.0.0 1
    t 1.0.0 1.1.0 0
    t 1.10.0 1.9.9 1
    t 1.0.0 1.0.0 0
    t 2.0 1.99.99 1
    [ "$(version_normalize v1.2.3)" = "1.2.3" ] && ok "normalize v1.2.3" || bad "normalize v1.2.3"
    version_normalize "latest" >/dev/null && bad "normalize 'latest' elfogadva" || ok "normalize 'latest' elutasítva"
    version_normalize "1.2.3; rm -rf /" >/dev/null && bad "normalize injekció" || ok "normalize injekció elutasítva"
    exit "$fail"
) || fail=1

# --- 2. kiadás összeállítása --------------------------------------------------
version="$(tr -d '[:space:]' <"$ROOT/VERSION")"
bash "$ROOT/tools/make-release.sh" "$TMP/dist" >/dev/null
asset="debian-kiosk-${version}.tar.gz"
[ -s "$TMP/dist/$asset" ] && ok "make-release: $asset" || bad "make-release nem készített csomagot"
[ -s "$TMP/dist/$asset.sha256" ] && ok "make-release: .sha256" || bad "make-release: nincs .sha256"
tar -tzf "$TMP/dist/$asset" >"$TMP/asset.list"
if grep -q "^debian-kiosk-${version}/install.sh$" "$TMP/asset.list"; then
    ok "csomag: install.sh a gyökérkönyvtárban"
else
    bad "csomag: install.sh hiányzik"
fi
if grep -qE '/(tests|tools)/' "$TMP/asset.list"; then
    bad "csomag: tests/tools nem kellene benne legyen"
else
    ok "csomag: tests/tools nélkül"
fi

API="$TMP/api"
REL_DIR="$API/repos/teszt/kiosk/releases"
mkdir -p "$REL_DIR"

write_release() {
    # write_release <tag> <asset fájl> <sha fájl|-> [prerelease]
    local tag="$1" a="$2" s="$3" pre="${4:-false}"
    jq -n --arg tag "$tag" --arg a "$a" --arg s "$s" --arg dir "$TMP/dist" \
        --argjson pre "$pre" '{
        tag_name: $tag, draft: false, prerelease: $pre,
        tarball_url: "",
        assets: ([
            {name: $a, browser_download_url: ("file://" + $dir + "/" + $a), url: ""}
        ] + (if $s == "-" then [] else [
            {name: $s, browser_download_url: ("file://" + $dir + "/" + $s), url: ""}
        ] end))
    }' >"$REL_DIR/latest.json"
}

conf="$TMP/kiosk.conf"
cat >"$conf" <<EOF
KIOSK_ETC=$TMP/etc
KIOSK_STATE=$TMP/state
KIOSK_RUN=$TMP/run
KIOSK_VERSION_FILE=$TMP/VERSION
UPDATE_ENABLED=1
UPDATE_GITHUB_OWNER=teszt
UPDATE_GITHUB_REPO=kiosk
UPDATE_TOKEN_FILE=$TMP/etc/update.token
UPDATE_API_BASE=file://$API
UPDATE_REQUIRE_CHECKSUM=1
UPDATE_SETUP_DIR=$TMP/setup
EOF

run_update() {
    local out="$1"
    shift
    set +e
    KIOSK_PREFIX="$PREFIX" KIOSK_CONF="$conf" KIOSK_UPDATE_ALLOW_FILE=1 TMPDIR="$TMP" \
        bash "$ROOT/bin/kiosk-update.sh" "$@" >"$out" 2>&1
    rc=$?
    set -e
}

expect() {
    # expect <név> <várt rc> <kimenet> <minta>
    local name="$1" want="$2" out="$3" pattern="$4"
    if [ "$rc" = "$want" ] && grep -Eq -- "$pattern" "$out"; then
        ok "$name"
    else
        bad "$name (rc=$rc, várt $want; minta: $pattern)"
        sed 's/^/       | /' "$out" | tail -n 6
    fi
}

echo "2) --check"
printf '1.0.0\n' >"$TMP/VERSION"
write_release "v${version}" "$asset" "$asset.sha256"
run_update "$TMP/o1" --check
expect "újabb verzió jelzése (exit 10)" 10 "$TMP/o1" "Új verzió érhető el: ${version}"
grep -q '^result=available$' "$TMP/state/update-status" && ok "update-status: available" || bad "update-status"

printf '%s\n' "$version" >"$TMP/VERSION"
run_update "$TMP/o2" --check
expect "naprakész (exit 0)" 0 "$TMP/o2" "naprakész"

printf '99.0.0\n' >"$TMP/VERSION"
run_update "$TMP/o3" --check
expect "régebbi kiadás nem downgrade-el" 0 "$TMP/o3" "naprakész"

echo "3) --dry-run (letöltés + ellenőrzés)"
printf '1.0.0\n' >"$TMP/VERSION"
run_update "$TMP/o4" --dry-run
expect "érvényes kiadás elfogadva" 0 "$TMP/o4" "Próbafutás rendben: ${version}"

cp "$TMP/dist/$asset.sha256" "$TMP/dist/good.sha256"
printf '%064d  %s\n' 0 "$asset" >"$TMP/dist/$asset.sha256"
run_update "$TMP/o5" --dry-run
expect "hibás SHA-256 elutasítva" 1 "$TMP/o5" "SHA-256 eltérés"
cp "$TMP/dist/good.sha256" "$TMP/dist/$asset.sha256"

write_release "v${version}" "$asset" "-"
run_update "$TMP/o6" --dry-run
expect "hiányzó .sha256 elutasítva" 1 "$TMP/o6" "nincs .*\.sha256"

# Tag és VERSION eltérés: a csomag ${version}, a tag 99.1.0
cp "$TMP/dist/$asset" "$TMP/dist/debian-kiosk-99.1.0.tar.gz"
(cd "$TMP/dist" && sha256sum debian-kiosk-99.1.0.tar.gz >debian-kiosk-99.1.0.tar.gz.sha256)
write_release "v99.1.0" "debian-kiosk-99.1.0.tar.gz" "debian-kiosk-99.1.0.tar.gz.sha256"
run_update "$TMP/o7" --dry-run
expect "tag/VERSION eltérés elutasítva" 1 "$TMP/o7" "nem egyezik"

write_release "v${version}" "nem-ez.tar.gz" "-"
run_update "$TMP/o8" --dry-run
expect "hiányzó csatolmány elutasítva" 1 "$TMP/o8" "nincs debian-kiosk-${version}\.tar\.gz"

write_release "v${version}" "$asset" "$asset.sha256" true
run_update "$TMP/o9" --dry-run
expect "pre-release kihagyva" 0 "$TMP/o9" "pre-release"

# Veszélyes archívum: '..' útvonal
mkdir -p "$TMP/evil/x"
printf 'x\n' >"$TMP/evil/x/a"
tar -C "$TMP/evil/x" -czf "$TMP/dist/debian-kiosk-99.2.0.tar.gz" --transform 's|^a$|../../a|' a 2>/dev/null || true
(cd "$TMP/dist" && sha256sum debian-kiosk-99.2.0.tar.gz >debian-kiosk-99.2.0.tar.gz.sha256)
write_release "v99.2.0" "debian-kiosk-99.2.0.tar.gz" "debian-kiosk-99.2.0.tar.gz.sha256"
run_update "$TMP/o10" --dry-run
expect "'..' útvonalas archívum elutasítva" 1 "$TMP/o10" "'\.\.' útvonalat"

echo "4) kikapcsolt önfrissítés"
printf 'UPDATE_ENABLED=0\n' >>"$conf"
write_release "v${version}" "$asset" "$asset.sha256"
run_update "$TMP/o11" --check
expect "--check kikapcsolt állapotban is tájékoztat" 10 "$TMP/o11" "Új verzió érhető el"

echo
if [ "$fail" = 0 ]; then
    echo "UPDATE-SMOKE: minden rendben"
else
    echo "UPDATE-SMOKE: HIBA"
    exit 1
fi
