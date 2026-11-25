#!/usr/bin/env bash
# =============================================================================
# Debian kiosk - USB import
#
# A udev szabály hívja meg, amikor egy USB-s tároló bekerül. A fájlokat
# csak olvashatóan csatolja, átmásolja az inboxba, majd elindítja a
# dokumentum-feldolgozást.
# =============================================================================
set -uo pipefail

export LOG_NAME="kiosk-usb"
# shellcheck source=/usr/lib/kiosk/common.sh
: "${KIOSK_PREFIX:=/usr}"
. "${KIOSK_PREFIX}/lib/kiosk/common.sh"
load_conf
require_root

dev="${1:-}"
[ -n "$dev" ] || die "Használat: $0 /dev/sdX1"
[ -b "$dev" ] || die "Nem blokk-eszköz: $dev"

base="${USB_MOUNT_ROOT:-/run/media/kiosk-usb}"
mkdir -p "$base" || die "Nem hozható létre: $base"
mp="$(mktemp -d "${base}/XXXXXX")" || die "mktemp hiba"

cleanup() {
    if mountpoint -q "$mp" 2>/dev/null; then
        umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
    fi
    rmdir "$mp" 2>/dev/null || true
}
trap cleanup EXIT

log "INFO" "USB csatolása (csak olvasható): ${dev}"
mount -o ro,nosuid,nodev,noexec "$dev" "$mp" 2>/dev/null || {
    log "WARN" "Nem sikerült csatolni: ${dev} (lehet, hogy nincs rajta fájlrendszer)"
    exit 0
}

mkdir -p "$INBOX_DIR" 2>/dev/null || die "Nem hozható létre: $INBOX_DIR"

count=0
while IFS= read -r -d '' f; do
    name="$(basename -- "$f")"
    case "$name" in .*) continue ;; esac

    dest="${INBOX_DIR}/${name}"
    if [ -e "$dest" ]; then
        stem="${name%.*}"
        ext="${name##*.}"
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
