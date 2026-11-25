#!/usr/bin/env bash
# =============================================================================
# Debian kiosk - renderelő
#
# A normalizált allowlistból legyártja:
#   - a helyi kezdőlapot ( /srv/kiosk/start.html )
#   - a Firefox ESR házirendet ( policies.json + könyvjelzők )
#   - a tinyproxy allowlist szűrőt és konfigurációt
# =============================================================================

# --- kezdőlap ---------------------------------------------------------------
render_startpage() {
    local norm="$1" out="$2" site_name="$3"
    local tmp
    tmp="$(mktemp)" || die "mktemp hiba"

    {
        cat <<EOF
<!DOCTYPE html>
<html lang="hu">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(html_escape "$site_name") - Kezdőlap</title>
<link rel="stylesheet" href="style.css">
<script src="theme.js"></script>
</head>
<body class="page-home" data-admin="http://127.0.0.1:${ADMIN_UI_PORT}/">
<header class="topbar">
  <button class="theme-toggle" id="theme-toggle" type="button"
          title="Sötét téma" aria-label="Sötét téma" aria-pressed="false">🌙</button>
  <div class="brand">$(html_escape "$site_name")</div>
  <form class="address" id="address-form" autocomplete="off">
    <input id="address" type="text" inputmode="url" spellcheck="false"
           placeholder="Weboldal címe…" aria-label="Weboldal címe">
    <button type="submit">Ugrás</button>
  </form>
  <button class="pin-unlock" id="unlock-btn" type="button"
          title="Szabad böngészés PIN-nel" aria-label="Szabad böngészés PIN-nel">
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <rect x="5" y="11" width="14" height="9" rx="2"></rect>
      <path d="M8 11V8a4 4 0 0 1 8 0v3"></path>
    </svg>
    PIN
  </button>
  <button class="pin-unlock lock-now" id="lock-btn" type="button"
          title="Böngészés azonnali lezárása" aria-label="Böngészés azonnali lezárása">
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <rect x="5" y="11" width="14" height="9" rx="2"></rect>
      <path d="M8 11V8a4 4 0 0 1 8 0v3"></path>
      <path d="M12 15v2"></path>
    </svg>
  </button>
  <div class="clock" id="clock">--:--</div>
</header>
<div class="unlock-modal" id="unlock-modal" hidden>
  <div class="unlock-dialog" role="dialog" aria-modal="true" aria-label="Szabad böngészés PIN-nel">
    <button class="unlock-close" id="unlock-close" type="button" aria-label="Bezárás">×</button>
    <iframe id="unlock-frame" title="Szabad böngészés PIN-nel" src="about:blank"></iframe>
    <a class="unlock-direct" id="unlock-direct" href="#">Megnyitás külön oldalon</a>
  </div>
</div>
<div class="unlock-toast" id="unlock-toast" role="status" hidden></div>
<main class="grid">
EOF
        jq -r '
          .sites[] |
          (if .allowed == false then " tile-blocked" else "" end) as $cls |
          "<a class=\"tile\($cls)\" href=\"\(.url | @html)\" data-url=\"\(.url | @html)\" rel=\"noreferrer\">\n" +
          "  <span class=\"tile-title\">\(.title | @html)</span>\n" +
          "  <span class=\"tile-url\">\(.url | @html)</span>\n" +
          (if .allowed == false then
             "  <span class=\"tile-lock\" title=\"PIN-nel nyitható meg\">PIN</span>\n"
           else "" end) +
          "</a>"
        ' "$norm"
        cat <<'EOF'
<a class="tile tile-docs" href="docs/index.html">
  <span class="tile-title">Helyi dokumentumok</span>
  <span class="tile-url">PDF &middot; Word &middot; Excel &middot; PowerPoint &middot; videó</span>
</a>
</main>
<footer class="footer">
EOF
        printf '  %s &middot; %s\n' "$(html_escape "$site_name")" "$(date '+%Y-%m-%d')"
        cat <<'EOF'
</footer>
<script src="clock.js"></script>
</body>
</html>
EOF
    } >"$tmp"

    atomic_install "$tmp" "$out" 0644 root root || {
        rm -f -- "$tmp"
        die "Nem sikerült kiírni a kezdőlapot: $out"
    }
    rm -f -- "$tmp"
}

# --- Firefox házirend -------------------------------------------------------
render_policies() {
    local norm="$1"
    local tmp dir
    tmp="$(mktemp)" || die "mktemp hiba"

    jq -n -f "${KIOSK_LIB:-/usr/lib/kiosk}/policies.jq" \
        --arg start_url "file://${START_PAGE}" \
        --arg downloads "${KIOSK_DOWNLOADS:-/var/lib/kiosk/Downloads}" \
        --arg folder "Engedélyezett oldalak" \
        --arg home_title "⌂ Kezdőlap" \
        --arg admin_ui "http://127.0.0.1:${ADMIN_UI_PORT:-8878}/" \
        --argjson proxy_port "${PROXY_PORT:-8877}" \
        --argjson enforce "${ENFORCE_ALLOWLIST:-1}" \
        --slurpfile al "$norm" >"$tmp" || {
        rm -f -- "$tmp"
        die "Hiba a policies.json generálásakor"
    }

    jq -e '.policies.Bookmarks | length >= 1' "$tmp" >/dev/null 2>&1 || {
        rm -f -- "$tmp"
        die "A generált policies.json hibás (nincs könyvjelző)"
    }

    if [ -n "${KIOSK_POLICY_DIR:-}" ]; then
        install -d -m 0755 "$KIOSK_POLICY_DIR"
        atomic_install "$tmp" "${KIOSK_POLICY_DIR}/policies.json" 0644 root root ||
            die "Nem sikerült kiírni: ${KIOSK_POLICY_DIR}/policies.json"
    else
        # Debian: /etc/firefox-esr/policies, upstream Firefox: /etc/firefox/policies
        for dir in /etc/firefox-esr/policies /etc/firefox/policies; do
            install -d -m 0755 "$dir"
            atomic_install "$tmp" "${dir}/policies.json" 0644 root root ||
                die "Nem sikerült kiírni: ${dir}/policies.json"
        done
    fi
    rm -f -- "$tmp"
}

# --- proxy szűrő ------------------------------------------------------------
# FONTOS: a tinyproxy a szűrőfájl minden sorát a sor belsejében lévő,
# escapeletlen '#' karakterig megjegyzésként levágja (filter.c). Ha a minta
# '#'-et tartalmazna, a truncált sor érvénytelen regex lenne, és a tinyproxy
# a filter_init-ben "Bad regex ..." hibával kilépne. Ezért a mintákban
# szándékosan nincs '#': a fragmentumot a ([:/?].*)? rész nem fedi le, de a
# szűrés úgyis csak a domainre megy (FilterURLs Off).
# Egy domainhez két minta kell: URL-alak (ha valaki FilterURLs-t használ) és
# "host(:port)" alak (ezt látja a tinyproxy CONNECT-nél, illetve domain
# szűrésnél a csupasz hostot).
_domain_patterns() {
    local d="$1" esc
    if [ "${d#\*.}" != "$d" ]; then
        # *.example.com  ->  csak aldomainek
        d="${d#\*.}"
        esc="${d//./\\.}"
        printf '^[a-z][a-z0-9+.-]*://([a-z0-9_-]+\\.)+%s([:/?].*)?$\n' "$esc"
        printf '^([a-z0-9_-]+\\.)+%s(:[0-9]+)?$\n' "$esc"
    else
        # example.com  ->  apex + összes aldomain
        esc="${d//./\\.}"
        printf '^[a-z][a-z0-9+.-]*://([a-z0-9_-]+\\.)*%s([:/?].*)?$\n' "$esc"
        printf '^([a-z0-9_-]+\\.)*%s(:[0-9]+)?$\n' "$esc"
    fi
}

render_proxy_filter() {
    local norm="$1" tmp
    tmp="$(mktemp)" || die "mktemp hiba"

    {
        printf '# Debian kiosk - automatikusan generált allowlist (ne szerkeszd!)\n'
        printf '# Forrás: GitHub allowlist.json - %s - %s oldal\n' \
            "$(date '+%F %T')" "$(jq -r '.site_count' "$norm")"
        printf '\n'
        {
            jq -r '.domains[]' "$norm"
            # Helyi, admin felületen engedélyezett (rejtett) domainek.
            hidden_hosts
        } | sort -u | while IFS= read -r d; do
            d="${d%$'\r'}"
            [ -n "$d" ] || continue
            _domain_patterns "$d"
        done
    } >"$tmp"

    # Védőháló: a tinyproxy a sort escapeletlen '#'-nél elvágja, ami érvénytelen
    # regexhez és a proxy el nem indulásához vezetne. Inkább itt álljunk meg.
    if grep -q '^\^.*#' "$tmp"; then
        rm -f -- "$tmp"
        die "A generált proxy szűrő '#'-et tartalmaz, a tinyproxy nem tudná betölteni"
    fi

    install -d -m 0755 "$(dirname "$PROXY_FILTER")"
    atomic_install "$tmp" "$PROXY_FILTER" 0644 root root || {
        rm -f -- "$tmp"
        die "Nem sikerült kiírni: $PROXY_FILTER"
    }
    rm -f -- "$tmp"
}

# --- proxy konfiguráció -----------------------------------------------------
render_proxy_conf() {
    local tmp
    local tpl="${KIOSK_PROXY_TEMPLATE:-/usr/share/kiosk/proxy/tinyproxy.conf.in}"
    [ -r "$tpl" ] || die "Hiányzó sablon: $tpl"
    tmp="$(mktemp)" || die "mktemp hiba"

    sed -e "s|@PROXY_PORT@|${PROXY_PORT:-8877}|g" \
        -e "s|@PROXY_FILTER@|${PROXY_FILTER}|g" \
        -e "s|@KIOSK_VERSION@|${KIOSK_VERSION}|g" \
        "$tpl" >"$tmp" || {
        rm -f -- "$tmp"
        die "Hiba a proxy konfiguráció generálásakor"
    }

    # PIN-es ideiglenes feloldás: a Filter* sorok kimaradnak, így a proxy
    # minden domaint átenged. A lejáratot a proxy_bypass_active() kezeli.
    if proxy_bypass_active; then
        if grep -vE '^[[:space:]]*(Filter|FilterType|FilterCaseSensitive|FilterDefaultDeny|FilterURLs)([[:space:]]|$)' \
            "$tmp" >"${tmp}.open"; then
            mv -f -- "${tmp}.open" "$tmp"
            log "WARN" "A proxy allowlist ideiglenesen fel van oldva (PIN-es bypass)"
        else
            rm -f -- "${tmp}.open"
            rm -f -- "$tmp"
            die "Nem sikerült a proxy bypass konfigurációt előállítani"
        fi
    fi

    install -d -m 0755 "$(dirname "$PROXY_CONF")"
    atomic_install "$tmp" "$PROXY_CONF" 0644 root root || {
        rm -f -- "$tmp"
        die "Nem sikerült kiírni: $PROXY_CONF"
    }
    rm -f -- "$tmp"
}

# --- helyi, látható oldalak ------------------------------------------------
# A /etc/kiosk/local-sites.local egy URL soronként; ezek a GitHub-lista
# mellé kerülnek a kezdőlapon és a könyvjelzők között is.
merge_local_sites() {
    local base="$1" file="${LOCAL_SITES_FILE:-${KIOSK_ETC:-/etc/kiosk}/local-sites.local}"
    [ -r "$file" ] || {
        cat -- "$base"
        return 0
    }

    local urls
    urls="$(jq -R -s '
        split("\n")
        | map(gsub("^\\s+|\\s+$"; ""))
        | map(select(length > 0 and (startswith("#") | not)))
    ' <"$file")" || return 1

    jq --argjson local "$urls" '
        def uhost:
            sub("^https?://"; ""; "i")
            | split("/")[0] | split("?")[0] | split("#")[0]
            | ascii_downcase
            | sub("\\.$"; "") | sub("^www\\."; "");

        . as $base
        | ($local | map(select(test("^https?://[^\\s\"<>]+$"; "i")))) as $urls
        | ($urls
           | map({ title: (uhost | .[0:80]), url: . })
           | map(select(.title != "" and (.title | test("^[a-z0-9*][a-z0-9.*-]*$"))))
           | unique_by(.url)) as $new
        | ($new | map(select(.url as $u | ($base.sites | map(.url) | index($u)) == null))) as $add
        | ($add | map(.title)) as $hosts
        | $base
        | .sites = (.sites + $add)
        | .domains = ((.domains + $hosts) | unique)
        | .site_count = (.sites | length)
    ' "$base"
}

# --- mindent egyben ---------------------------------------------------------
render_all() {
    local norm="${1:-${KIOSK_STATE:-/var/lib/kiosk/state}/allowlist.json}"
    local merged=""
    [ -r "$norm" ] || die "Hiányzó normalizált allowlist: $norm"
    validate_allowlist "$norm" || die "Érvénytelen allowlist: $norm"

    local sites_file="${LOCAL_SITES_FILE:-${KIOSK_ETC:-/etc/kiosk}/local-sites.local}"
    if [ -s "$sites_file" ]; then
        merged="$(mktemp)" || die "mktemp hiba"
        merge_local_sites "$norm" >"$merged" || {
            rm -f -- "$merged"
            die "A helyi oldalak beolvasása nem sikerült: $sites_file"
        }
        validate_allowlist "$merged" || {
            rm -f -- "$merged"
            die "A helyi oldalakkal együtt érvénytelen az allowlist"
        }
        norm="$merged"
    fi

    install -d -m 0755 "$(dirname "$START_PAGE")" "$DOCS_DIR" "${KIOSK_ETC:-/etc/kiosk}"

    render_startpage "$norm" "$START_PAGE" "${SITE_NAME:-Kiosk}"
    install -m 0644 "${KIOSK_WEB_DIR:-/usr/share/kiosk/web}/style.css" \
        "$(dirname "$START_PAGE")/style.css"
    clock_src="${KIOSK_WEB_DIR:-/usr/share/kiosk/web}/clock.js"
    if [ -r "$clock_src" ]; then
        install -m 0644 "$clock_src" "$(dirname "$START_PAGE")/clock.js"
    else
        log "WARN" "Hiányzó clock.js (${clock_src}) - a fejlécben csak a helyőrző látszik"
    fi
    theme_src="${KIOSK_WEB_DIR:-/usr/share/kiosk/web}/theme.js"
    if [ -r "$theme_src" ]; then
        install -m 0644 "$theme_src" "$(dirname "$START_PAGE")/theme.js"
    else
        log "WARN" "Hiányzó theme.js (${theme_src}) - a témaváltó nem működik"
    fi
    render_policies "$norm"
    render_proxy_filter "$norm"
    render_proxy_conf

    log "INFO" "Render kész: $(jq -r '.site_count' "$norm") engedélyezett oldal, $(jq -r '.domains | length' "$norm") domain"
    if [ -n "$merged" ]; then
        rm -f -- "$merged"
    fi
}
