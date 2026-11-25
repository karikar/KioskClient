#!/usr/bin/env bash
# =============================================================================
# Debian kiosk - a felület újragenerálása a cache-elt allowlistból
# (hálózat nélkül). Akkor hasznos, ha kézzel módosítottad a konfigurációt
# vagy a stílust.
# =============================================================================
set -euo pipefail

export LOG_NAME="kiosk-render"
: "${KIOSK_PREFIX:=/usr}"
# shellcheck source=/usr/lib/kiosk/common.sh
. "${KIOSK_PREFIX}/lib/kiosk/common.sh"
# shellcheck source=/usr/lib/kiosk/render.sh
. "${KIOSK_PREFIX}/lib/kiosk/render.sh"
load_conf
require_root

render_all "${1:-${KIOSK_STATE}/allowlist.json}"

if [ "${KIOSK_NO_RELOAD:-0}" != "1" ]; then
    notify_session_reload
fi
