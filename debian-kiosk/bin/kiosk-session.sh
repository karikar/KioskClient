#!/usr/bin/env bash
# =============================================================================
# Debian kiosk - böngésző session
#
# Egyetlen Wayland kliens: cage (kiosk compositor) + firefox-esr.
# Ha a böngésző bezárul vagy lefagy, a ciklus újraindítja.
# Xorg nélkül fut (Wayland, KMS/DRM).
# =============================================================================
set -uo pipefail

export LOG_NAME="kiosk-session"
# shellcheck source=/usr/lib/kiosk/common.sh
: "${KIOSK_PREFIX:=/usr}"
. "${KIOSK_PREFIX}/lib/kiosk/common.sh"
load_conf

export HOME="${KIOSK_HOME}"
export XDG_CACHE_HOME="${HOME}/.cache"
export MOZ_ENABLE_WAYLAND=1
export GDK_BACKEND=wayland
export MOZ_CRASHREPORTER_DISABLE=1
export MOZ_CRASHREPORTER_SHUTDOWN=1
export MOZ_DISABLE_AUTO_SAFE_MODE=1

# Magyar nyelv a böngészőhöz (ha a locale telepítve van).
if [ -n "${KIOSK_LANG:-}" ] && locale -a 2>/dev/null | grep -qi "^${KIOSK_LANG%%.*}\."; then
    export LANG="$KIOSK_LANG"
    export LANGUAGE="${KIOSK_LANG%%_*}"
fi

# Magyar billentyűzet a cage/Wayland alatt: a wlroots az XKB_DEFAULT_*
# környezeti változókat olvassa (a hu layout adja az áéíóöőúüű karaktereket).
export XKB_DEFAULT_LAYOUT="${KEYBOARD_LAYOUT:-hu}"
export XKB_DEFAULT_MODEL="${KEYBOARD_MODEL:-pc105}"
export XKB_DEFAULT_VARIANT="${KEYBOARD_VARIANT:-}"
export XKB_DEFAULT_OPTIONS="${KEYBOARD_OPTIONS:-}"

# XDG_RUNTIME_DIR: a logind általában beállítja, de SSH-ból indított
# teszteknél hiányozhat.
if [ -z "${XDG_RUNTIME_DIR:-}" ] || [ ! -d "${XDG_RUNTIME_DIR}" ]; then
    if [ -d "/run/user/$(id -u)" ] && [ -w "/run/user/$(id -u)" ]; then
        XDG_RUNTIME_DIR="/run/user/$(id -u)"
    else
        XDG_RUNTIME_DIR="/tmp/kiosk-runtime-$(id -u)"
        mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
        chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
    fi
fi
export XDG_RUNTIME_DIR

command -v cage >/dev/null 2>&1 || die "A 'cage' nincs telepítve (apt install cage)."
command -v firefox-esr >/dev/null 2>&1 || die "A 'firefox-esr' nincs telepítve."

mkdir -p "$KIOSK_PROFILE/chrome" "$KIOSK_DOWNLOADS" "$KIOSK_STATE" 2>/dev/null || true

# A könyvjelzőket és a kezdőlapot a Firefox-házirend adja. A places.sqlite
# törlésével érjük el, hogy a menü minden indításkor pontosan az allowlist
# legyen (a törölt oldalak ne maradjanak benne).
prepare_profile() {
    mkdir -p "$KIOSK_PROFILE/chrome" 2>/dev/null || true
    if [ -r "${KIOSK_FIREFOX_DIR}/user.js" ]; then
        cp -f "${KIOSK_FIREFOX_DIR}/user.js" "$KIOSK_PROFILE/user.js"
    fi
    if [ -r "${KIOSK_FIREFOX_DIR}/userChrome.css" ]; then
        cp -f "${KIOSK_FIREFOX_DIR}/userChrome.css" "$KIOSK_PROFILE/chrome/userChrome.css"
    fi

    rm -f "$KIOSK_PROFILE/places.sqlite" \
          "$KIOSK_PROFILE/places.sqlite-wal" \
          "$KIOSK_PROFILE/places.sqlite-shm" \
          "$KIOSK_PROFILE/favicons.sqlite" \
          "$KIOSK_PROFILE/favicons.sqlite-wal" \
          "$KIOSK_PROFILE/favicons.sqlite-shm" \
          "$KIOSK_PROFILE/sessionstore.jsonlz4" \
          "$KIOSK_PROFILE/.parentlock" \
          "$KIOSK_PROFILE/lock" 2>/dev/null || true
    # A könyvjelző-mentésekből a Firefox üres places.sqlite mellett
    # visszaállítana - ez okozta a dupla "Engedélyezett oldalak" mappát.
    rm -rf "$KIOSK_PROFILE/sessionstore-backups" \
           "$KIOSK_PROFILE/bookmarkbackups" 2>/dev/null || true
}

cleanup_firefox() {
    pkill -TERM -u "$(id -u)" -x firefox-esr 2>/dev/null || true
    sleep 1
    pkill -KILL -u "$(id -u)" -x firefox-esr 2>/dev/null || true
}

# A sync script a /run/kiosk/restart flaggel kéri az újraindítást.
reload_watch() {
    local pid="$1"
    while kill -0 "$pid" 2>/dev/null; do
        if [ -e "${KIOSK_RUN}/restart" ]; then
            rm -f "${KIOSK_RUN}/restart" 2>/dev/null || true
            log "INFO" "Allowlist frissült - a böngésző újraindul"
            kill -TERM "$pid" 2>/dev/null || true
            return 0
        fi
        sleep 3
    done
}

# Ha a proxy még nem állt fel (pl. boot után), várjunk rá, hogy a böngésző
# ne a "proxy server is refusing connections" oldallal induljon.
wait_for_proxy() {
    [ "${ENFORCE_ALLOWLIST:-1}" = "1" ] || return 0
    local _i
    for _i in $(seq 1 24); do
        if (exec 3<>"/dev/tcp/127.0.0.1/${PROXY_PORT}") 2>/dev/null; then
            return 0
        fi
        sleep 0.5
    done
    log "WARN" "A proxy (127.0.0.1:${PROXY_PORT}) nem válaszol - a böngésző hálózati hibát mutathat."
    return 1
}

trap 'cleanup_firefox; exit 0' INT TERM HUP

log "INFO" "Kiosk session indul (cage + firefox-esr, profil: ${KIOSK_PROFILE})"

while :; do
    rm -f "${KIOSK_RUN}/restart" 2>/dev/null || true
    prepare_profile
    wait_for_proxy || true
    started="$(date +%s)"

    # A GitHub allowlist "resolution" mezője (ha van) a cage indulása előtt.
    resolution=""
    if [ -r "${KIOSK_STATE}/allowlist.json" ] && command -v jq >/dev/null 2>&1; then
        resolution="$(jq -r '.resolution // ""' "${KIOSK_STATE}/allowlist.json" 2>/dev/null || true)"
    fi
    export KIOSK_RESOLUTION="$resolution"
    export KIOSK_PROFILE

    cage -- sh -c 'if [ -n "${KIOSK_RESOLUTION:-}" ]; then /usr/local/bin/kiosk-set-resolution.sh "$KIOSK_RESOLUTION" || true; fi; exec firefox-esr --no-remote --profile "$KIOSK_PROFILE"' &
    cage_pid=$!

    reload_watch "$cage_pid" &
    watch_pid=$!

    wait "$cage_pid"
    rc=$?

    kill "$watch_pid" 2>/dev/null || true
    wait "$watch_pid" 2>/dev/null || true
    cleanup_firefox

    runtime=$(( $(date +%s) - started ))
    if [ "$runtime" -lt 10 ]; then
        log "WARN" "A böngésző azonnal leállt (rc=${rc}, ${runtime}s) - 5 mp múlva újra"
        sleep 5
    else
        log "WARN" "A böngésző leállt (rc=${rc}) - 2 mp múlva újraindul"
        sleep 2
    fi
done
