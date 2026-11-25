#!/usr/bin/env bash
# =============================================================================
# Debian kiosk - belépéskori jelentés
#
# Minden belépéskor (PAM open_session: login, sshd, ...) összegyűjti:
#   - a nyilvános IP-címet,
#   - az időpontot (ISO 8601, helyi időzónával),
#   - a kiosk naplójának utolsó sorait,
# és egy .log fájlként feltölti a megadott GitHub repóba (Contents API).
#
# A PAM-ból a --pam kapcsolóval hívjuk: azonnal visszaadja a vezérlést, a
# tényleges munkát systemd tranziens unit (vagy háttérfolyamat) végzi, így
# a bejelentkezés nem lassul a hálózat miatt.
#
# Kézi próba:
#   sudo kiosk-admin.sh report --dry-run   # csak kiírja, mit küldene
#   sudo kiosk-admin.sh report             # tényleges feltöltés
# =============================================================================
set -uo pipefail

export LOG_NAME="login-report"
: "${KIOSK_PREFIX:=/usr}"
# shellcheck source=/usr/lib/kiosk/common.sh
. "${KIOSK_PREFIX}/lib/kiosk/common.sh"

# --- PAM gyors út: ne blokkoljuk a bejelentkezést ---------------------------
if [ "${1:-}" = "--pam" ]; then
    shift
    [ "${PAM_TYPE:-}" = "open_session" ] || exit 0
    case "${PAM_SERVICE:-}" in
        login | sshd | gdm | gdm-password | gdm-wayland-session | lightdm | sddm) ;;
        *) exit 0 ;;
    esac

    args=(--user "${PAM_USER:-}" --service "${PAM_SERVICE:-}"
          --tty "${PAM_TTY:-}" --source "${PAM_RHOST:-}")

    if command -v systemd-run >/dev/null 2>&1; then
        if systemd-run --quiet --collect --no-block \
            --unit="kiosk-login-report-$(date +%s)-$$" \
            --description="Kiosk login report (${PAM_USER:-?})" \
            /usr/local/bin/kiosk-login-report.sh "${args[@]}" \
            >/dev/null 2>&1; then
            exit 0
        fi
    fi

    # systemd nélkül (pl. teszt): leválasztott háttérfolyamat.
    if command -v setsid >/dev/null 2>&1; then
        setsid nohup /usr/local/bin/kiosk-login-report.sh "${args[@]}" \
            >/dev/null 2>&1 </dev/null &
    else
        nohup /usr/local/bin/kiosk-login-report.sh "${args[@]}" \
            >/dev/null 2>&1 </dev/null &
    fi
    exit 0
fi

# --- argumentumok -----------------------------------------------------------
dry_run=0
user="${USER:-$(id -un 2>/dev/null || echo unknown)}"
service="manual"
tty=""
source=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --user) user="${2:-}"; shift 2 || break ;;
        --service) service="${2:-}"; shift 2 || break ;;
        --tty) tty="${2:-}"; shift 2 || break ;;
        --source) source="${2:-}"; shift 2 || break ;;
        --dry-run) dry_run=1; shift ;;
        *) shift ;;
    esac
done

load_conf

if [ "${REPORT_ENABLED:-0}" != "1" ]; then
    if [ "$dry_run" = 1 ]; then
        printf 'A belépéskori jelentés ki van kapcsolva (REPORT_ENABLED=0).\n'
    else
        log "INFO" "Belépéskori jelentés kikapcsolva (REPORT_ENABLED=0)"
    fi
    exit 0
fi

owner="${REPORT_GITHUB_OWNER:-${GITHUB_OWNER:-}}"
repo="${REPORT_GITHUB_REPO:-${GITHUB_REPO:-}}"
ref="${REPORT_GITHUB_REF:-${GITHUB_REF:-main}}"
prefix="${REPORT_PATH:-login-logs}"
token_file="${REPORT_TOKEN_FILE:-${KIOSK_ETC}/report.token}"
log_lines="${REPORT_LOG_LINES:-200}"

[ -n "$owner" ] && [ -n "$repo" ] ||
    die "Nincs beállítva a jelentés célrepója (REPORT_GITHUB_OWNER/REPORT_GITHUB_REPO)"

safe() { printf '%s' "${1:-}" | tr -c 'A-Za-z0-9._-' '-'; }

host="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo kiosk)"
host="$(safe "$host")"
user_safe="$(safe "$user")"
now_iso="$(date '+%Y-%m-%dT%H:%M:%S%:z')"
day="$(date '+%Y-%m-%d')"
stamp="$(date '+%H%M%S')"

is_ip() {
    case "${1:-}" in
        "" | *[!0-9a-fA-F:.]*) return 1 ;;
    esac
    return 0
}

# --- nyilvános IP -----------------------------------------------------------
public_ip="${KIOSK_REPORT_IP:-}"
if [ -z "$public_ip" ]; then
    round=1
    while [ "$round" -le 3 ] && [ -z "$public_ip" ]; do
        for url in "https://api.ipify.org" "https://ipv4.icanhazip.com" \
            "https://ifconfig.me/ip"; do
            candidate="$(curl --silent --show-error --fail --max-time 5 \
                --noproxy '*' --proto '=https' \
                -A "debian-kiosk/${KIOSK_VERSION:-1.0.0}" \
                "$url" 2>/dev/null | tr -d '[:space:]')" || candidate=""
            if is_ip "$candidate"; then
                public_ip="$candidate"
                break
            fi
        done
        [ -n "$public_ip" ] && break
        sleep 4
        round=$((round + 1))
    done
fi
[ -n "$public_ip" ] || public_ip="unknown"

# --- naplófájl összeállítása ------------------------------------------------
tmp=""
payload=""
cfg=""
resp=""
cleanup() { rm -f -- "$tmp" "$payload" "$cfg" "$resp" 2>/dev/null || true; }
trap cleanup EXIT

tmp="$(mktemp)" || die "mktemp hiba"

{
    printf '# Debian kiosk - belépéskori jelentés\n'
    printf '# Automatikusan készült; a GitHubon a %s/ könyvtár alatt található.\n' "$prefix"
    printf 'timestamp: %s\n' "$now_iso"
    printf 'hostname: %s\n' "$host"
    printf 'public_ip: %s\n' "$public_ip"
    printf 'user: %s\n' "${user:-unknown}"
    printf 'service: %s\n' "${service:-unknown}"
    printf 'tty: %s\n' "${tty:-}"
    printf 'source: %s\n' "${source:-local}"
    printf 'kernel: %s\n' "$(uname -srm 2>/dev/null || echo unknown)"
    printf 'uptime: %s\n' "$(uptime -p 2>/dev/null || echo unknown)"
    printf 'boot_id: %s\n' "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
    printf '\n# --- napló (utolsó %s sor a kiosk egységekből) ---\n' "$log_lines"
    journalctl -b -n "$log_lines" -o short-iso --no-pager \
        -t kiosk-session -t kiosk-sync -t kiosk-docs -t kiosk-proxy \
        -t kiosk-usb -t kiosk-login-report 2>/dev/null || true
    printf '\n# --- sikertelen systemd egységek ---\n'
    systemctl --failed --no-legend --no-pager 2>/dev/null || true
} >"$tmp"

# Helyi másolat a hibakereséshez (a kiosk felhasználó nem olvashatja).
if [ -d "${KIOSK_STATE:-}" ]; then
    install -m 0600 "$tmp" "${KIOSK_STATE}/last-login-report.log" 2>/dev/null || true
fi

rel_path="${prefix}/${host}/${day}/${stamp}-${user_safe}.log"

if [ "$dry_run" = 1 ]; then
    printf 'Célrepó : %s/%s@%s\n' "$owner" "$repo" "$ref"
    printf 'Fájl    : %s\n' "$rel_path"
    printf 'IP      : %s\n' "$public_ip"
    printf 'Időpont : %s\n' "$now_iso"
    printf '%s\n' '--- a feltöltendő napló ---'
    cat -- "$tmp"
    exit 0
fi

# --- token ------------------------------------------------------------------
token=""
if [ -r "$token_file" ]; then
    token="$(tr -d '[:space:]' <"$token_file")"
fi
if [ -z "$token" ]; then
    log "WARN" "Nincs jelentés token (${token_file}) - a jelentés kimaradt"
    exit 0
fi

# --- feltöltés a GitHub Contents API-val ------------------------------------
api="https://api.github.com/repos/${owner}/${repo}/contents/${rel_path}"
message="Login report: ${host} ${now_iso} (${public_ip})"

payload="$(mktemp)" || die "mktemp hiba"
cfg="$(mktemp)" || die "mktemp hiba"
resp="$(mktemp)" || die "mktemp hiba"
chmod 600 "$payload" "$cfg" 2>/dev/null || true

# A naplót jq-val kódoljuk, így a tartalom nem kerül a parancssorba.
jq -n --arg message "$message" --arg branch "$ref" --rawfile log "$tmp" \
    '{message: $message, content: ($log | @base64), branch: $branch}' \
    >"$payload" || die "Nem sikerült összeállítani a JSON kérést"

{
    printf 'header = "Authorization: Bearer %s"\n' "$token"
    printf 'header = "Accept: application/vnd.github+json"\n'
    printf 'header = "X-GitHub-Api-Version: 2022-11-28"\n'
    printf 'user-agent = "debian-kiosk/%s"\n' "${KIOSK_VERSION:-1.0.0}"
} >"$cfg"

attempt=1
while :; do
    code="$(curl --silent --show-error --location --proto '=https' \
        --max-time 30 --config "$cfg" \
        -X PUT -H 'Content-Type: application/json' \
        --data-binary @"$payload" -o "$resp" -w '%{http_code}' \
        "$api" 2>/dev/null)" || code="000"

    case "$code" in
        200 | 201)
            log "INFO" "Jelentés feltöltve: ${owner}/${repo}/${rel_path} (${public_ip})"
            exit 0
            ;;
        401 | 403)
            log "ERROR" "Hitelesítési hiba (HTTP ${code}) - rossz/lejárt token, vagy nincs Contents: Read and write jog"
            exit 1
            ;;
        404)
            log "ERROR" "HTTP 404 - nincs ilyen repó/ág: ${owner}/${repo}@${ref}"
            exit 1
            ;;
        409 | 422)
            log "ERROR" "HTTP ${code} - a fájl már létezik, vagy a kérés érvénytelen: ${rel_path}"
            exit 1
            ;;
    esac

    if [ "$attempt" -ge 4 ]; then
        log "ERROR" "Nem sikerült feltölteni a jelentést (HTTP ${code})"
        exit 1
    fi
    sleep $((attempt * 5))
    attempt=$((attempt + 1))
done
