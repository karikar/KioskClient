# ---------------------------------------------------------------------------
# Debian kiosk - allowlist normalizáló (jq 1.6+)
#
# Bemenet: a GitHubon tárolt allowlist.json, két lehetséges sémában:
#
#   A) "örökölt" (a jelenlegi karikar/kiosk repó formátuma)
#      {
#        "start_url": "https://...",
#        "allowed_domains":  ["https://...", ...],
#        "allowed_prefixes": ["https://...", ...],
#        "refresh_interval_seconds": 300
#      }
#
#   B) "sites" (bővített, szebb menücímekkel)
#      {
#        "start_url": "https://...",
#        "sites": [ { "title": "TippMix", "url": "https://www.tippmix.hu/" } ],
#        "extra_domains": ["cdn.example.com"],
#        "hidden_urls": ["https://hidden.example.org/belső-oldal"],
#        "refresh_interval_seconds": 300,
#        "resolution": "1366x768"
#      }
#
#   A "sites" elem opcionális "allowed": false mezője látható, de proxyból
#   tiltott oldalt jelent (a csempe/bookmark megjelenik, a domain nem megy át).
#
#   A "hidden_urls" elemei (teljes URL, csupasz domain vagy
#   { "title": "...", "url": "..." } objektum) a proxy allowlistjára
#   felkerülnek, de a kezdőlapon és a könyvjelzők között NEM jelennek meg.
#
# Kimenet: stabil, normalizált szerkezet, ezt fogyasztja a renderelő.
# ---------------------------------------------------------------------------

def s: if type == "string" then . else "" end;

def trim: gsub("^\\s+"; "") | gsub("\\s+$"; "");

def lc: ascii_downcase;

def host_of($u):
  ($u | capture("^https?://(?<h>[^/:?#]+)") | .h | lc | sub("\\.$"; ""));

def strip_www: sub("^www\\."; "");

def hostkey($u): host_of($u) | strip_www;

# "Rejtett" engedélyezés: a bejegyzés csak a proxy domainlistájára kerül,
# a menübe (sites) nem. Teljes URL vagy csupasz domain is megadható,
# illetve { "title": "...", "url": "..." } objektum is (a title itt nem
# jelenik meg, mert a bejegyzés rejtett).
def hidden_value:
  if type == "object" then ((.url // "") | s) else s end;

def hidden_host:
  (hidden_value | trim) as $v
  | if ($v | test("^https?://[^/:?#]+")) then
      (try (host_of($v) | strip_www) catch empty)
    elif ($v | test("^[A-Za-z0-9*][A-Za-z0-9.*-]*$")) then
      ($v | lc | sub("\\.$"; "") | strip_www)
    else
      empty
    end
  | select(test("^[a-z0-9*][a-z0-9.*-]*$"));

def path_of($u):
  ($u | sub("^https?://[^/]*"; "") | sub("[?#].*$"; "") | sub("/+$"; ""));

def humanize:
  gsub("[_\\-]+"; " ")
  | gsub("\\.(html?|php|aspx?|jsp|cgi)$"; "")
  | gsub("\\s+"; " ")
  | trim
  | .[0:30]
  | split(" ")
  | map(select(length > 0) | (.[0:1] | ascii_upcase) + .[1:])
  | join(" ");

# Generáltnak tűnő útvonal-szegmens (hash, hosszú azonosító) - ne kerüljön a menübe.
def looks_generated:
  test("[0-9a-fA-F]{16,}") or test("^[0-9]{6,}$") or (length > 28);

def boring_segment($seg):
  ($seg | lc) as $l
  | ($l == ""
     or $l == "index"
     or $l == "index.html"
     or $l == "index.php"
     or $l == "home"
     or $l == "main"
     or $l == "default.aspx"
     or ($seg | looks_generated));

def title_for($u):
  (host_of($u) | strip_www) as $base
  | (path_of($u) | split("/") | map(select(length > 0)) | last // "") as $seg
  | if boring_segment($seg) then $base
    else "\($base) - \($seg | humanize)"
    end;

. as $raw
| (if ($raw | type) == "object" then $raw else {} end) as $in

# 1) explicit "sites" tömb
| (if ($in.sites | type) == "array" then $in.sites else [] end
   | map(select(type == "object"))
   | map({ title: ((.title // "") | s | trim),
           url:   ((.url   // "") | s | trim),
           allowed: (if .allowed == false then false
                     elif (.allowed == null) or (.allowed == true) then true
                     else error("a sites[].allowed csak igaz/hamis lehet") end) })) as $explicit

# 2) örökölt listák (URL-ek és/vagy csupasz domainek)
| ([ ($in.allowed_prefixes // []), ($in.allowed_domains // []) ]
   | map(if type == "array" then . else [] end)
   | add // []
   | map(select(type == "string") | trim)
   | map(select(length > 0))) as $legacy_all

| ($legacy_all | map(select(test("^https?://")))) as $legacy_urls
| ($legacy_all
   | map(select(test("^https?://") | not))
   | map(select(test("^[A-Za-z0-9*._-]+$")))) as $legacy_bare

| ($explicit + ($legacy_urls | map({ title: "", url: ., allowed: true }))) as $combined

# 3) szűrés, cím-generálás, duplikátumok kivétele (első nyer)
| ($combined
   | map(select(.url | test("^https?://[^\\s\"<>]+$")))
   | map({ title: (if .title == "" then title_for(.url)
                   else (.title | .[0:80]) end),
           url: .url,
           allowed: .allowed })
   | reduce .[] as $x ([]; if any(.[]; .url == $x.url) then . else . + [$x] end)
  ) as $sites0

# 4) a start_url az a cím, amit a kiosk megnyit. Ha a sites listában van,
#    a helyén marad (így az admin sorrendje érvényesül); ha hiányzik, elölre
#    kerül. Csak www/apex eltérésnél frissítjük a meglévő elem URL-jét.
| (($in.start_url // "") | s | trim) as $start0
| ($sites0
   | if $start0 == "" then .
     else
       (map(.url) | index($start0)) as $exact
       | if $exact != null then
           .
         else
           (map(hostkey(.url)) | index(hostkey($start0))) as $byhost
           | if $byhost != null then
               (to_entries
                | map(if .key == $byhost then (.value | .url = $start0) else .value end))
             else
               [{ title: title_for($start0), url: $start0, allowed: true }] + .
             end
         end
     end) as $sites

# 5) domainlista a proxyhoz (a www levágva, hogy az apex + összes aldomain is átmenjen)
| (($in.hidden_urls // []) | if type == "array" then . else [] end
   | map(hidden_host)) as $hidden

| ([ $sites[] | select(.allowed != false) | hostkey(.url) ]
   + ($legacy_bare | map(sub("^www\\."; "")))
   + (if ($in.extra_domains | type) == "array"
      then [ $in.extra_domains[] | s | trim | lc | sub("^www\\."; "") | select(length > 0) ]
      else [] end)
   + $hidden) as $domains_raw

# A tiltott oldal domainje minden más engedélyezést felülír (ha nincs
# szülő-domain ütközés; azt az admin validáció jelzi).
| ([ $sites[] | select(.allowed == false) | hostkey(.url) ]) as $blocked_hosts

| {
    version: 1,
    start_url: (if $start0 != "" then $start0 else ($sites[0].url // "") end),
    refresh_interval_seconds: (
      ($in.refresh_interval_seconds // 300)
      | if (type == "number") and (. >= 30) then . else 300 end
    ),
    resolution: (($in.resolution // "") | s | trim),
    sites: $sites,
    domains: (($domains_raw | map(select(length > 0)) | unique) - $blocked_hosts),
    hidden_domains: (($hidden | map(select(length > 0)) | unique) - $blocked_hosts),
    site_count: ($sites | length)
  }
