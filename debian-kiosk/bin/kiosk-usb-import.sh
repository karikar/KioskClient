#!/usr/bin/env bash
# =============================================================================
# Debian kiosk - USB import
#
#   kiosk-usb-import.sh /dev/sdX1             bedugáskor (udev -> systemd)
#   kiosk-usb-import.sh --release /dev/sdX1   kihúzáskor / kiadáskor
#
# Két mód (USB_IMPORT_MODE a kiosk.conf-ban, az admin felület felülírhatja a
# /var/lib/kiosk/state/usb-import-mode fájllal):
#
#   manual (alap) - az USB-t csak olvashatóan csatolja a
#                   /run/media/kiosk-usb/<eszköz> alá, és csatolva hagyja;
#                   az admin felület "USB tallózó" kártyáján választható ki,
#                   mi kerüljön be. Kihúzáskor/kiadáskor leválasztja.
#   auto          - minden támogatott fájlt bemásol az inboxba, feldolgozza,
#                   majd leválasztja (a korábbi viselkedés).
# =============================================================================
set -uo pipefail

export LOG_NAME="kiosk-usb"
# shellcheck source=/usr/lib/kiosk/common.sh
: "${KIOSK_PREFIX:=/usr}"
. "${KIOSK_PREFIX}/lib/kiosk/common.sh"
load_conf
require_root

release=0
if [ "${1:-}" = "--release" ]; then
    release=1
    shift
fi

dev="${1:-}"
[ -n "$dev" ] || die "Használat: $0 [--release] /dev/sdX1"
name="$(basename -- "$dev")"
case "$name" in "" | *[!A-Za-z0-9_-]*) die "Érvénytelen eszköznév: $dev" ;; esac

base="${USB_MOUNT_ROOT:-/run/media/kiosk-usb}"
fixed_mp="${base}/${name}"
info_file="${base}/.${name}.json"

# --- leválasztás (kihúzás vagy "Kiadás" gomb) -------------------------------
release_usb() {
    if mountpoint -q "$fixed_mp" 2>/dev/null; then
        umount "$fixed_mp" 2>/dev/null || umount -l "$fixed_mp" 2>/dev/null || true
        log "INFO" "USB leválasztva: ${dev}"
    fi
    rmdir "$fixed_mp" 2>/dev/null || true
    rm -f -- "$info_file"
}

if [ "$release" = 1 ]; then
    release_usb
    exit 0
fi

[ -b "$dev" ] || die "Nem blokk-eszköz: $dev"
mkdir -p "$base" || die "Nem hozható létre: $base"
chmod 0755 "$base" 2>/dev/null || true

mode="${USB_IMPORT_MODE:-manual}"
if [ -r "${KIOSK_STATE}/usb-import-mode" ]; then
    mode="$(tr -d '[:space:]' <"${KIOSK_STATE}/usb-import-mode")"
fi
case "$mode" in auto | manual) ;; *) mode="manual" ;; esac

mount_opts="ro,nosuid,nodev,noexec"

# --- kézi mód: csatolva hagyjuk, az admin felület választ ------------------
if [ "$mode" = "manual" ]; then
    release_usb
    mkdir -p "$fixed_mp" || die "Nem hozható létre: $fixed_mp"
    log "INFO" "USB csatolása (csak olvasható, kézi kiválasztáshoz): ${dev}"
    if ! mount -o "$mount_opts" "$dev" "$fixed_mp" 2>/dev/null; then
        rmdir "$fixed_mp" 2>/dev/null || true
        log "WARN" "Nem sikerült csatolni: ${dev} (lehet, hogy nincs rajta fájlrendszer)"
        exit 0
    fi
    label="$(blkid -o value -s LABEL "$dev" 2>/dev/null || true)"
    fstype="$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)"
    size_bytes="$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)"
    jq -n --arg id "$name" --arg dev "$dev" --arg label "$label" \
        --arg fstype "$fstype" --argjson size "${size_bytes:-0}" \
        --arg mounted "$(date '+%F %T')" \
        '{id: $id, dev: $dev, label: $label, fstype: $fstype, size: $size, mounted: $mounted}' \
        >"$info_file" 2>/dev/null || true
    log "INFO" "USB elérhető az admin felületen (USB tallózó): ${label:-$name}"
    exit 0
fi

# --- automatikus mód: minden támogatott fájl bemásolása ---------------------
mp="$(mktemp -d "${base}/auto.XXXXXX")" || die "mktemp hiba"

cleanup() {
    if mountpoint -q "$mp" 2>/dev/null; then
        umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
    fi
    rmdir "$mp" 2>/dev/null || true
}
trap cleanup EXIT

log "INFO" "USB csatolása (csak olvasható, automatikus import): ${dev}"
mount -o "$mount_opts" "$dev" "$mp" 2>/dev/null || {
    log "WARN" "Nem sikerült csatolni: ${dev} (lehet, hogy nincs rajta fájlrendszer)"
    exit 0
}

mkdir -p "$INBOX_DIR" 2>/dev/null || die "Nem hozható létre: $INBOX_DIR"

count=0
while IFS= read -r -d '' f; do
    fname="$(basename -- "$f")"
    case "$fname" in .*) continue ;; esac

    dest="${INBOX_DIR}/${fname}"
    if [ -e "$dest" ]; then
        stem="${fname%.*}"
        ext="${fname##*.}"
        i=1
        while [ -e "$dest" ]; do
            dest="${INBOX_DIR}/${stem}-${i}.${ext}"
            i=$((i + 1))
        done
    fi

    if cp -- "$f" "$dest" 2>/dev/null; then
        chown "${KIOSK_USER}:${KIOSK_USER}" "$dest" 2>/dev/null || true
        chmod 0644 "$dest" 2>/dev/null || true
        count=$((count + 1))
    fi
done < <(find "$mp" -maxdepth 3 -type f \
    \( -iname '*.pdf' -o -iname '*.txt' -o -iname '*.md' \
    -o -iname '*.doc' -o -iname '*.docx' -o -iname '*.odt' -o -iname '*.rtf' \
    -o -iname '*.xls' -o -iname '*.xlsx' -o -iname '*.ods' -o -iname '*.csv' \
    -o -iname '*.ppt' -o -iname '*.pptx' -o -iname '*.odp' \
    -o -iname '*.mp4' -o -iname '*.m4v' -o -iname '*.webm' -o -iname '*.mkv' \
    -o -iname '*.mov' -o -iname '*.avi' -o -iname '*.ogv' -o -iname '*.mp3' \
    -o -iname '*.wav' -o -iname '*.m4a' \
    -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
    -o -iname '*.gif' -o -iname '*.webp' -o -iname '*.svg' -o -iname '*.bmp' \) \
    -size -"${MAX_FILE_MB:-2048}"M -print0 2>/dev/null)

log "INFO" "USB: ${count} fájl átmásolva ide: ${INBOX_DIR}"

if [ "$count" -gt 0 ]; then
    # A path unit is figyeli az inboxot, de itt determinisztikusan lefuttatjuk.
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$KIOSK_USER" -- /usr/local/bin/kiosk-docs.sh || \
            log "WARN" "A dokumentum-feldolgozás nem indult el"
    fi
fi
