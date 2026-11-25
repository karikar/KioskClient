#!/usr/bin/env bash
# =============================================================================
# Debian kiosk - dokumentum feldolgozás
#
# A /srv/kiosk/inbox könyvtárba tett fájlokból:
#   - Word / Excel / PowerPoint / OpenDocument / RTF / CSV  ->  PDF (LibreOffice)
#   - PDF, kép, szöveg, videó, hang                        ->  közvetlen megnyitás
#
# Majd újragenerálja a /srv/kiosk/docs/index.html listát, amit a kiosk
# kezdőlapján a "Dokumentumok" csempe nyit meg.
#
# systemd path unit hívja, a kiosk felhasználóként fut.
# =============================================================================
set -uo pipefail

export LOG_NAME="kiosk-docs"
# shellcheck source=/usr/lib/kiosk/common.sh
: "${KIOSK_PREFIX:=/usr}"
. "${KIOSK_PREFIX}/lib/kiosk/common.sh"
load_conf

export HOME="${KIOSK_HOME}"
TMPDIR="${TMPDIR:-/tmp}"

# Egyszerre csak egy feldolgozás fusson (path unit + USB import is hívhatja).
if command -v flock >/dev/null 2>&1 && [ -d "${KIOSK_RUN}" ] && [ -w "${KIOSK_RUN}" ]; then
    exec 9>"${KIOSK_RUN}/docs.lock" || true
    if ! flock -w 120 9; then
        log "INFO" "Egy másik feldolgozás még fut, kilépés"
        exit 0
    fi
fi

mkdir -p "$DOCS_DIR" "$INBOX_DIR/processed" 2>/dev/null || true
touch "$DOCS_DIR/.origins" 2>/dev/null || true

OFFICE_EXT="doc docx odt rtf xls xlsx ods csv ppt pptx odp pps ppsx"
DIRECT_EXT="pdf txt md jpg jpeg png gif webp svg bmp"
VIDEO_EXT="mp4 m4v webm mkv mov avi ogv mp3 wav m4a"

ext_in() {
    local e="$1" list="$2" x
    for x in $list; do
        [ "$x" = "$e" ] && return 0
    done
    return 1
}

# A böngészőből vagy USB-ről érkező fájl még íródhat - megvárjuk a végét.
wait_stable() {
    local f="$1" s1 s2
    for _ in 1 2 3 4 5; do
        s1="$(stat -c %s "$f" 2>/dev/null || echo 0)"
        sleep 0.6
        s2="$(stat -c %s "$f" 2>/dev/null || echo 0)"
        if [ "$s1" = "$s2" ] && [ "$s1" != "0" ]; then
            return 0
        fi
    done
    return 1
}

convert_office() {
    local src="$1" ext="$2" base outdir pdf
    base="$(basename -- "$src")"
    base="${base%.*}"
    outdir="$(mktemp -d)" || return 1

    if timeout 240 soffice --headless --norestore --nolockcheck --nodefault \
        --convert-to pdf --outdir "$outdir" "$src" >/dev/null 2>&1; then
        pdf="$(find "$outdir" -maxdepth 1 -type f -name '*.pdf' -print -quit 2>/dev/null)"
        if [ -n "$pdf" ] && install -m 0644 "$pdf" "$DOCS_DIR/${base}.pdf"; then
            printf '%s\t%s\n' "${base}.pdf" "$ext" >>"$DOCS_DIR/.origins"
            rm -rf "$outdir"
            log "INFO" "Konvertálva: ${base} (${ext} -> PDF)"
            return 0
        fi
    fi

    rm -rf "$outdir"
    log "ERROR" "Nem sikerült konvertálni: ${base}"
    return 1
}

badge_for() {
    local ext="$1" base="$2"
    if [ -n "${ORIGIN[$base]:-}" ]; then
        printf '%s → PDF' "$(printf '%s' "${ORIGIN[$base]}" | tr '[:lower:]' '[:upper:]')"
        return
    fi
    case "$ext" in
        pdf) printf 'PDF' ;;
        mp4 | m4v | webm | mkv | mov | avi | ogv) printf 'VIDEÓ' ;;
        mp3 | wav | m4a) printf 'HANG' ;;
        jpg | jpeg | png | gif | webp | svg | bmp) printf 'KÉP' ;;
        txt | md) printf 'SZÖVEG' ;;
        *) printf '%s' "$(printf '%s' "$ext" | tr '[:lower:]' '[:upper:]')" ;;
    esac
}

render_docs_index() {
    local tmp found=0
    declare -A ORIGIN=()
    if [ -s "$DOCS_DIR/.origins" ]; then
        while IFS=$'\t' read -r k v; do
            [ -n "$k" ] && ORIGIN["$k"]="$v"
        done <"$DOCS_DIR/.origins"
    fi

    tmp="$(mktemp)" || return 1

    {
        cat <<EOF
<!DOCTYPE html>
<html lang="hu">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Dokumentumok</title>
<link rel="stylesheet" href="../style.css">
<script src="../theme.js"></script>
</head>
<body class="page-docs" data-admin="http://127.0.0.1:${ADMIN_UI_PORT}/">
<header class="docs-head">
  <button class="theme-toggle" id="theme-toggle" type="button"
          title="Sötét téma" aria-label="Sötét téma" aria-pressed="false">🌙</button>
  <a class="back" href="../start.html">&#8592; Kezdőlap</a>
  <div class="brand">Dokumentumok</div>
  <a class="docs-manage" href="http://127.0.0.1:${ADMIN_UI_PORT}/#docs">Dokumentumok kezelése (PIN)</a>
  <div class="clock" id="clock">--:--</div>
</header>
<main class="docs">
EOF

        while IFS=$'\t' read -r -d '' ts size path; do
            [ -n "$path" ] || continue
            case "$path" in
                */.* | */index.html) continue ;;
            esac
            [ -f "$path" ] || continue

            local base ext name url badge human_size when
            base="${path##*/}"
            ext="${base##*.}"
            ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
            name="${base%.*}"
            name="${name//_/ }"
            url="$(file_url "$path")"
            badge="$(badge_for "$ext" "$base")"
            human_size="$(numfmt --to=iec --suffix=B --format='%.1f' "$size" 2>/dev/null || printf '%s B' "$size")"
            when="$(date -d "@${ts}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '')"

            found=1
            if ext_in "$ext" "$VIDEO_EXT" && ext_in "$ext" "mp4 m4v webm mkv mov avi ogv"; then
                printf '<article class="doc doc-video-wrap">\n'
                printf '  <video class="doc-video" controls preload="metadata" src="%s"></video>\n' "$(html_escape "$url")"
                printf '  <span class="doc-badge">%s</span>\n' "$(html_escape "$badge")"
                printf '  <span class="doc-name">%s</span>\n' "$(html_escape "$name")"
                printf '  <span class="doc-meta">%s &middot; %s</span>\n' "$(html_escape "$human_size")" "$(html_escape "$when")"
                printf '</article>\n'
            elif ext_in "$ext" "mp3 wav m4a"; then
                printf '<article class="doc">\n'
                printf '  <audio controls preload="metadata" src="%s" style="width:100%%"></audio>\n' "$(html_escape "$url")"
                printf '  <span class="doc-badge">%s</span>\n' "$(html_escape "$badge")"
                printf '  <span class="doc-name">%s</span>\n' "$(html_escape "$name")"
                printf '</article>\n'
            else
                printf '<a class="doc" href="%s">\n' "$(html_escape "$url")"
                printf '  <span class="doc-badge">%s</span>\n' "$(html_escape "$badge")"
                printf '  <span class="doc-name">%s</span>\n' "$(html_escape "$name")"
                printf '  <span class="doc-meta">%s &middot; %s</span>\n' "$(html_escape "$human_size")" "$(html_escape "$when")"
                printf '</a>\n'
            fi
        done < <(find "$DOCS_DIR" -maxdepth 1 -type f \
            ! -name 'index.html' ! -name '.origins' \
            -printf '%T@\t%s\t%p\0' 2>/dev/null | sort -z -rn)

        if [ "$found" = 0 ]; then
            cat <<'EOF'
<p class="empty">
  <strong>Még nincs dokumentum.</strong><br>
  Csatlakoztass egy USB-meghajtót, vagy helyezz fájlt a kiosk inbox könyvtárába.
</p>
EOF
        fi

        cat <<'EOF'
</main>
<script src="../clock.js"></script>
</body>
</html>
EOF
    } >"$tmp"

    install -m 0644 "$tmp" "$DOCS_DIR/index.html" || {
        rm -f -- "$tmp"
        log "ERROR" "Nem sikerült kiírni: ${DOCS_DIR}/index.html"
        return 1
    }
    rm -f -- "$tmp"
}

# --- fő ciklus --------------------------------------------------------------
processed_count=0

shopt -s nullglob
for src in "$INBOX_DIR"/*; do
    [ -f "$src" ] || continue
    base="$(basename -- "$src")"
    case "$base" in .*) continue ;; esac

    ext="${base##*.}"
    ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"

    size="$(stat -c %s "$src" 2>/dev/null || echo 0)"
    size_mb=$(( (size + 1048575) / 1048576 ))

    if [ "$size_mb" -gt "${MAX_FILE_MB:-2048}" ]; then
        log "WARN" "Túl nagy fájl (${size_mb} MB), kihagyva: ${base}"
        mv -f -- "$src" "$INBOX_DIR/processed/skipped-$(date +%s)-${base}" 2>/dev/null || true
        continue
    fi

    if ! wait_stable "$src"; then
        log "WARN" "A fájl még íródik, később dolgozzuk fel: ${base}"
        continue
    fi

    ok=0
    moved=0
    if ext_in "$ext" "$OFFICE_EXT"; then
        if convert_office "$src" "$ext"; then
            ok=1
        fi
    elif ext_in "$ext" "$DIRECT_EXT" || ext_in "$ext" "$VIDEO_EXT"; then
        # Ugyanazon a fájlrendszeren mozgatunk, így nem készül dupla másolat.
        if mv -f -- "$src" "$DOCS_DIR/${base}"; then
            chmod 0644 "$DOCS_DIR/${base}" 2>/dev/null || true
            ok=1
            moved=1
        fi
    else
        log "WARN" "Nem támogatott fájltípus: .${ext} (${base})"
    fi

    if [ "$ok" = 1 ]; then
        if [ "$moved" = 0 ]; then
            mv -f -- "$src" "$INBOX_DIR/processed/$(date +%s)-${base}" 2>/dev/null || \
                rm -f -- "$src"
        fi
        processed_count=$((processed_count + 1))
    elif [ -f "$src" ]; then
        mv -f -- "$src" "$INBOX_DIR/processed/failed-$(date +%s)-${base}" 2>/dev/null || true
    fi
done

# Régi átmeneti példányok takarítása
find "$INBOX_DIR/processed" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null || true

log "INFO" "Feldolgozva: ${processed_count} fájl"
render_docs_index || die "A dokumentumlista generálása nem sikerült"
