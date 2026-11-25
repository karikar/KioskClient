#!/usr/bin/env bash
# =============================================================================
# Debian kiosk - program önfrissítés GitHub Release-ből
#
#   kiosk-update.sh             van újabb kiadás? ha igen, telepíti
#   kiosk-update.sh --check     csak ellenőrzés (kilépési kód 10 = van újabb)
#   kiosk-update.sh --dry-run   letölt + ellenőriz, de nem telepít
#   kiosk-update.sh --force     a legutóbbi kiadás telepítése akkor is, ha nem
#                               újabb, vagy korábban hibásnak lett jelölve
#   kiosk-update.sh --now       azonnal (karbantartási ablak és UPDATE_ENABLED=0
#                               figyelmen kívül; az admin felület gombja)
#
# Működés:
#   1. GitHub API: /repos/<owner>/<repo>/releases/latest (draft és pre-release
#      nélkül), a tag (v1.2.3) a kiadott verzió;
#   2. ha újabb, mint a /usr/share/kiosk/VERSION, letölti a
#      <UPDATE_ASSET_PREFIX>-<verzió>.tar.gz csatolmányt és a .sha256 párját;
#   3. SHA-256 ellenőrzés, biztonságos kicsomagolás, VERSION egyezés, bash -n;
#   4. a kiadás install.sh-ját frissítő módban futtatja (a beállítások, tokenek,
#      PIN megmaradnak);
#   5. hiba esetén visszatelepíti az előző kiadást, és a hibás verziót
#      megjelöli, hogy ne próbálkozzon vele óránként újra.
# =============================================================================
set -euo pipefail

export LOG_NAME="kiosk-update"
# shellcheck source=/usr/lib/kiosk/common.sh
: "${KIOSK_PREFIX:=/usr}"
. "${KIOSK_PREFIX}/lib/kiosk/common.sh"
load_conf

MODE="update"
FORCE=0
NOW=0
while [ $# -gt 0 ]; do
    case "$1" in
        --check) MODE="check" ;;
        --dry-run) MODE="dry-run" ;;
        --force) FORCE=1 ;;
        --now) NOW=1 ;;
        -h | --help)
            sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) die "Ismeretlen opció: $1" ;;
    esac
    shift
done

EXIT_NEWER=10

if [ "$MODE" = "update" ]; then
    require_root
fi

if [ "${UPDATE_ENABLED:-1}" != "1" ] && [ "$MODE" = "update" ] && [ "$FORCE" != "1" ] && [ "$NOW" != "1" ]; then
    log "INFO" "Az önfrissítés ki van kapcsolva (UPDATE_ENABLED=0)."
    exit 0
fi

[ -n "${UPDATE_GITHUB_OWNER:-}" ] || die "UPDATE_GITHUB_OWNER nincs beállítva (${KIOSK_CONF})"
[ -n "${UPDATE_GITHUB_REPO:-}" ] || die "UPDATE_GITHUB_REPO nincs beállítva (${KIOSK_CONF})"
command -v jq >/dev/null 2>&1 || die "A jq hiányzik."
command -v curl >/dev/null 2>&1 || die "A curl hiányzik."

repo="${UPDATE_GITHUB_OWNER}/${UPDATE_GITHUB_REPO}"
api_base="${UPDATE_API_BASE%/}"
state_dir="${KIOSK_STATE}"
failed_file="${state_dir}/update-failed"
status_file="${state_dir}/update-status"

# --- egyszerre csak egy futás ----------------------------------------------
lock_dir="${KIOSK_RUN}"
[ -d "$lock_dir" ] && [ -w "$lock_dir" ] || lock_dir="${TMPDIR:-/tmp}"
if command -v flock >/dev/null 2>&1; then
    exec 9>"${lock_dir}/kiosk-update.lock"
    if ! flock -n 9; then
        log "INFO" "Egy másik frissítés már fut - kihagyva."
        exit 0
    fi
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/kiosk-update.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
chmod 700 "$work"

# --- curl beállítás (token csak fájlból, nem argv-ből) ---------------------
curl_cfg="${work}/curl.cfg"
: >"$curl_cfg"
chmod 600 "$curl_cfg"
have_token=0
if [ -r "${UPDATE_TOKEN_FILE}" ]; then
    token="$(tr -d '[:space:]' <"${UPDATE_TOKEN_FILE}")"
    if [ -n "$token" ]; then
        printf 'header = "Authorization: Bearer %s"\n' "$token" >"$curl_cfg"
        have_token=1
    fi
    unset token
fi

# Éles használatban csak HTTPS; a füsttesztek file:// URL-t használnak.
proto="=https"
if [ "${KIOSK_UPDATE_ALLOW_FILE:-0}" = "1" ]; then
    proto="=https,file"
fi

# fetch <url> <kimenet> <Accept> [max bájt] -> HTTP kód a stdout-on
fetch() {
    local url="$1" out="$2" accept="$3" max="${4:-104857600}"
    curl --silent --show-error --location \
        --proto "$proto" --proto-redir '=https' \
        --max-time 600 --connect-timeout 20 --max-filesize "$max" \
        --retry 3 --retry-delay 3 --retry-all-errors \
        --config "$curl_cfg" \
        -H "Accept: ${accept}" \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        -H "User-Agent: debian-kiosk-updater/${KIOSK_VERSION}" \
        -o "$out" -w '%{http_code}' "$url"
}

write_status() {
    # kulcs=érték sorok; a kiosk-admin.sh status olvassa
    [ -d "$state_dir" ] && [ -w "$state_dir" ] || return 0
    {
        printf 'checked=%s\n' "$(date '+%F %T')"
        printf 'installed=%s\n' "$installed"
        printf 'latest=%s\n' "${latest:-}"
        printf 'result=%s\n' "$1"
    } >"${status_file}.tmp" 2>/dev/null && mv -f "${status_file}.tmp" "$status_file" 2>/dev/null || true
}

installed="$(installed_version)"
latest=""

# --- 1. legfrissebb kiadás lekérdezése -------------------------------------
release_json="${work}/release.json"
if [ "${api_base#file://}" != "$api_base" ]; then
    release_url="${api_base}/repos/${repo}/releases/latest.json"
else
    release_url="${api_base}/repos/${repo}/releases/latest"
fi

if ! code="$(fetch "$release_url" "$release_json" 'application/vnd.github+json' 2097152)"; then
    write_status "network-error"
    die "Hálózati hiba a kiadás lekérdezésekor (${repo})."
fi
case "$code" in
    200 | 000) ;; # 000: file:// (teszt)
    401 | 403)
        write_status "auth-error"
        die "HTTP ${code}: hozzáférés megtagadva (${repo}). Privát repónál kell az ${UPDATE_TOKEN_FILE} (Contents: Read), vagy elérte a rate limitet."
        ;;
    404)
        write_status "no-release"
        if [ "$have_token" = 1 ]; then
            die "HTTP 404: nincs kiadás (release) a ${repo} repóban, vagy a token nem látja."
        fi
        die "HTTP 404: nincs kiadás a ${repo} repóban (privát repónál token kell: ${UPDATE_TOKEN_FILE})."
        ;;
    *)
        write_status "http-${code}"
        die "Váratlan HTTP státusz a kiadás lekérdezésekor: ${code}"
        ;;
esac

jq -e 'type == "object" and (.tag_name | type) == "string"' "$release_json" >/dev/null 2>&1 ||
    die "A GitHub válasza nem értelmezhető kiadás (release) JSON."

tag="$(jq -r '.tag_name' "$release_json")"
latest="$(version_normalize "$tag")" || {
    write_status "bad-tag"
    die "A kiadás tagje nem verziószám: '${tag}' (elvárt: v1.2.3)."
}

if [ "$(jq -r '.draft // false' "$release_json")" = "true" ] ||
    [ "$(jq -r '.prerelease // false' "$release_json")" = "true" ]; then
    write_status "prerelease"
    log "INFO" "A legutóbbi kiadás (${tag}) draft/pre-release - kihagyva."
    exit 0
fi

log "INFO" "Telepítve: ${installed}, legutóbbi kiadás: ${latest} (${repo})"

if ! version_gt "$latest" "$installed" && [ "$FORCE" != "1" ]; then
    write_status "up-to-date"
    log "INFO" "A kiosk naprakész."
    exit 0
fi

if [ "$MODE" = "check" ]; then
    if version_gt "$latest" "$installed"; then
        write_status "available"
        printf 'Új verzió érhető el: %s (telepítve: %s)\n' "$latest" "$installed"
        exit "$EXIT_NEWER"
    fi
    printf 'Naprakész: %s\n' "$installed"
    exit 0
fi

if [ -r "$failed_file" ] && [ "$(tr -d '[:space:]' <"$failed_file")" = "$latest" ] && [ "$FORCE" != "1" ]; then
    write_status "skipped-failed"
    log "WARN" "A ${latest} telepítése korábban nem sikerült - kihagyva (kézzel: kiosk-update.sh --force)."
    exit 0
fi

# Karbantartási ablak (pl. UPDATE_WINDOW=02-05: 02:00 és 04:59 között).
if [ -n "${UPDATE_WINDOW:-}" ] && [ "$MODE" = "update" ] && [ "$FORCE" != "1" ] && [ "$NOW" != "1" ]; then
    if [[ "$UPDATE_WINDOW" =~ ^([0-9]{1,2})-([0-9]{1,2})$ ]]; then
        w_from=$((10#${BASH_REMATCH[1]}))
        w_to=$((10#${BASH_REMATCH[2]}))
        hour=$((10#$(date +%H)))
        in_window=0
        if [ "$w_from" -le "$w_to" ]; then
            [ "$hour" -ge "$w_from" ] && [ "$hour" -lt "$w_to" ] && in_window=1
        else
            { [ "$hour" -ge "$w_from" ] || [ "$hour" -lt "$w_to" ]; } && in_window=1
        fi
        if [ "$in_window" != 1 ]; then
            write_status "waiting-window"
            log "INFO" "Új verzió (${latest}) elérhető, telepítés a karbantartási ablakban (${UPDATE_WINDOW} óra)."
            exit 0
        fi
    else
        log "WARN" "Érvénytelen UPDATE_WINDOW='${UPDATE_WINDOW}' (elvárt: ÓÓ-ÓÓ) - figyelmen kívül hagyva."
    fi
fi

# --- 2. csatolmány kiválasztása és letöltése -------------------------------
asset_name="${UPDATE_ASSET_PREFIX}-${latest}.tar.gz"
# Tokennel az API-s asset URL kell (privát repó), anélkül a böngészős link is jó.
asset_field="browser_download_url"
[ "$have_token" = 1 ] && asset_field="url"

asset_url="$(jq -r --arg n "$asset_name" --arg f "$asset_field" \
    '[.assets[]? | select(.name == $n) | .[$f]] | first // empty' "$release_json")"
sum_url="$(jq -r --arg n "${asset_name}.sha256" --arg f "$asset_field" \
    '[.assets[]? | select(.name == $n) | .[$f]] | first // empty' "$release_json")"

archive="${work}/release.tar.gz"
if [ -n "$asset_url" ]; then
    log "INFO" "Letöltés: ${asset_name}"
    code="$(fetch "$asset_url" "$archive" 'application/octet-stream')" ||
        die "A kiadás letöltése nem sikerült (${asset_name})."
    case "$code" in 200 | 000) ;; *) die "A kiadás letöltése HTTP ${code} hibával tért vissza." ;; esac
elif [ "${UPDATE_REQUIRE_CHECKSUM}" != "1" ]; then
    tarball_url="$(jq -r '.tarball_url // empty' "$release_json")"
    [ -n "$tarball_url" ] || die "A kiadásban nincs ${asset_name} és tarball_url sem."
    log "WARN" "Nincs ${asset_name} csatolmány - a forráskód-archívumot töltöm le (ellenőrzőösszeg nélkül)."
    code="$(fetch "$tarball_url" "$archive" 'application/vnd.github+json')" ||
        die "A forráskód-archívum letöltése nem sikerült."
    case "$code" in 200 | 000) ;; *) die "A forráskód-archívum letöltése HTTP ${code} hibával tért vissza." ;; esac
else
    write_status "missing-asset"
    die "A ${tag} kiadásban nincs ${asset_name} csatolmány (a release workflow készíti). UPDATE_REQUIRE_CHECKSUM=0 mellett a forráskód-archívum is elfogadható."
fi

[ -s "$archive" ] || die "A letöltött archívum üres."

# --- 3. ellenőrzőösszeg ----------------------------------------------------
if [ -n "$sum_url" ]; then
    sum_file="${work}/release.sha256"
    code="$(fetch "$sum_url" "$sum_file" 'application/octet-stream' 4096)" ||
        die "Az ellenőrzőösszeg letöltése nem sikerült."
    case "$code" in 200 | 000) ;; *) die "Az ellenőrzőösszeg letöltése HTTP ${code} hibával tért vissza." ;; esac
    want="$(head -n 1 "$sum_file" | awk '{print tolower($1)}')"
    [[ "$want" =~ ^[0-9a-f]{64}$ ]] || die "Hibás formátumú ellenőrzőösszeg fájl."
    got="$(sha256_file "$archive")"
    if [ "$got" != "$want" ]; then
        write_status "checksum-mismatch"
        die "SHA-256 eltérés! várt: ${want}, kapott: ${got} - a frissítés megszakítva."
    fi
    log "INFO" "SHA-256 rendben."
elif [ -n "$asset_url" ]; then
    if [ "${UPDATE_REQUIRE_CHECKSUM}" = "1" ]; then
        write_status "missing-checksum"
        die "A ${tag} kiadásban nincs ${asset_name}.sha256 - ellenőrzés nélkül nem telepítek."
    fi
    log "WARN" "Nincs .sha256 csatolmány - ellenőrzőösszeg nélkül folytatom."
fi

# --- 4. biztonságos kicsomagolás --------------------------------------------
list="${work}/list.txt"
tar -tzf "$archive" >"$list" 2>/dev/null || die "A letöltött fájl nem érvényes tar.gz."
if grep -qE '^/|(^|/)\.\.(/|$)' "$list"; then
    die "Az archívum abszolút vagy '..' útvonalat tartalmaz - elutasítva."
fi

extract="${work}/extract"
mkdir -p "$extract"
tar -xzf "$archive" -C "$extract" --no-same-owner --no-same-permissions ||
    die "A kicsomagolás nem sikerült."
# Linkek nem kellenek a kiosk forrásában; ha vannak, elutasítjuk.
if [ -n "$(find "$extract" -type l -print -quit)" ]; then
    die "Az archívum szimbolikus linket tartalmaz - elutasítva."
fi

# Az install.sh lehet a gyökérben, egy alkönyvtárban (asset), vagy kettővel
# lejjebb (GitHub forráskód-archívum: <owner>-<repo>-<sha>/debian-kiosk/).
src=""
while IFS= read -r f; do
    d="$(dirname -- "$f")"
    if [ -r "${d}/VERSION" ] && [ -r "${d}/lib/common.sh" ]; then
        src="$d"
        break
    fi
done < <(find "$extract" -maxdepth 3 -type f -name install.sh | sort)
[ -n "$src" ] || die "Az archívumban nincs install.sh + VERSION + lib/common.sh."

pkg_version="$(tr -d '[:space:]' <"${src}/VERSION")"
if [ "$pkg_version" != "$latest" ]; then
    write_status "version-mismatch"
    die "A csomag VERSION fájlja (${pkg_version}) nem egyezik a kiadás tagjével (${latest})."
fi

while IFS= read -r -d '' f; do
    bash -n "$f" 2>"${work}/syntax.err" || {
        write_status "syntax-error"
        die "Szintaktikai hiba a kiadásban: ${f#"$src"/} - $(head -n 1 "${work}/syntax.err")"
    }
done < <(find "$src" -name '*.sh' -type f -print0)
if command -v python3 >/dev/null 2>&1 && [ -r "${src}/bin/kiosk-admin-ui.py" ]; then
    python3 -c 'import ast,sys; ast.parse(open(sys.argv[1],encoding="utf-8").read())' \
        "${src}/bin/kiosk-admin-ui.py" 2>/dev/null || die "Szintaktikai hiba: bin/kiosk-admin-ui.py"
fi

log "INFO" "A ${latest} kiadás ellenőrizve."

if [ "$MODE" = "dry-run" ]; then
    printf 'Próbafutás rendben: %s letölthető és ellenőrzött (telepítve: %s).\n' "$latest" "$installed"
    exit 0
fi

# --- 5. telepítés -----------------------------------------------------------
releases="${UPDATE_SETUP_DIR}/releases"
install -d -m 0755 "$releases"
target="${releases}/${latest}"
prev_dir="$(readlink -f "${UPDATE_SETUP_DIR}/current" 2>/dev/null || true)"

rm -rf -- "${target}.new"
cp -a -- "$src" "${target}.new"
chown -R root:root "${target}.new"
# --force esetén ugyanaz a verzió is lehet: a régi forrást lecseréljük.
rm -rf -- "$target"
mv -- "${target}.new" "$target"

update_log="/var/log/kiosk-update.log"
log "INFO" "Telepítés: ${installed} -> ${latest} (napló: ${update_log})"
{
    printf '\n===== %s  %s -> %s =====\n' "$(date '+%F %T')" "$installed" "$latest"
} >>"$update_log" 2>/dev/null || true

run_installer() {
    local dir="$1"
    (
        cd "$dir" &&
            KIOSK_UNATTENDED=1 KIOSK_UPGRADE=1 KIOSK_VERSION="" \
                bash "${dir}/install.sh" </dev/null
    ) >>"$update_log" 2>&1
}

if run_installer "$target" && [ "$(installed_version)" = "$latest" ]; then
    rm -f -- "$failed_file"
    write_status "updated"
    log "INFO" "Frissítés kész: ${latest}"

    # régi kiadások takarítása (a mostani és az előző mindig marad)
    keep="${UPDATE_KEEP_RELEASES:-2}"
    case "$keep" in "" | *[!0-9]*) keep=2 ;; esac
    [ "$keep" -ge 2 ] || keep=2
    find "$releases" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null |
        grep -E '^[0-9]' | sort -V | head -n "-${keep}" |
        while IFS= read -r old; do
            [ "${releases}/${old}" = "$target" ] && continue
            [ "${releases}/${old}" = "$prev_dir" ] && continue
            rm -rf -- "${releases:?}/${old}"
            log "INFO" "Régi kiadás törölve: ${old}"
        done
    exit 0
fi

# --- 6. visszaállás ---------------------------------------------------------
log "ERROR" "A ${latest} telepítése nem sikerült - részletek: ${update_log}"
printf '%s\n' "$latest" >"$failed_file" 2>/dev/null || true
write_status "failed"

if [ -n "$prev_dir" ] && [ "$prev_dir" != "$target" ] && [ -r "${prev_dir}/install.sh" ]; then
    log "WARN" "Visszaállás az előző kiadásra: $(basename -- "$prev_dir")"
    if run_installer "$prev_dir"; then
        log "INFO" "Visszaállás kész: $(installed_version)"
    else
        log "ERROR" "A visszaállás sem sikerült - kézi beavatkozás kell (${update_log})."
    fi
else
    log "ERROR" "Nincs korábbi telepítési forrás (${UPDATE_SETUP_DIR}/current) - visszaállás nem lehetséges."
fi
exit 1
