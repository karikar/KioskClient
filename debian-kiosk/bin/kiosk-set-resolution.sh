#!/usr/bin/env bash
# =============================================================================
# Debian kiosk - kijelző felbontás beállítása a cage/Wayland sessionben
#
# A kiosk-session.sh hívja a cage alatt (a WAYLAND_DISPLAY már be van állítva),
# a Firefox elindítása előtt. A kért módot a wlr-randr-ral állítja be az első
# kimeneten. Hiba esetén nem állítja meg a böngészőt; csak naplóz.
#
# Használat: kiosk-set-resolution.sh 1366x768
# =============================================================================
set -uo pipefail

mode="${1:-}"
case "$mode" in
    "" | auto | Auto | AUTO)
        exit 0
        ;;
    [0-9][0-9][0-9]x[0-9][0-9][0-9] | [0-9][0-9][0-9][0-9]x[0-9][0-9][0-9] | \
    [0-9][0-9][0-9]x[0-9][0-9][0-9][0-9] | [0-9][0-9][0-9][0-9]x[0-9][0-9][0-9][0-9])
        ;;
    *)
        echo "kiosk-set-resolution: érvénytelen mód: $mode" >&2
        exit 0
        ;;
esac

if ! command -v wlr-randr >/dev/null 2>&1; then
    echo "kiosk-set-resolution: a wlr-randr nincs telepítve - a felbontás nem változik" >&2
    exit 0
fi

if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    echo "kiosk-set-resolution: nincs WAYLAND_DISPLAY - a felbontás nem változik" >&2
    exit 0
fi

output=""
for _i in $(seq 1 24); do
    output="$(wlr-randr 2>/dev/null | awk 'NF && $0 !~ /^[[:space:]]/ { print $1; exit }')"
    [ -n "$output" ] && break
    sleep 0.25
done

if [ -z "$output" ]; then
    echo "kiosk-set-resolution: nem található kimenet - a felbontás nem változik" >&2
    exit 0
fi

if wlr-randr --output "$output" --mode "$mode" >/dev/null 2>&1; then
    echo "kiosk-set-resolution: ${output} -> ${mode}" >&2
else
    echo "kiosk-set-resolution: a(z) ${mode} mód nem állítható be a(z) ${output} kimeneten" >&2
fi

exit 0
