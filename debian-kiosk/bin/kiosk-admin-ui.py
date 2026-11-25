#!/usr/bin/env python3
# =============================================================================
# Debian kiosk - admin felület kiszolgálója
#
# 127.0.0.1:8878 - csak helyi hozzáférés, X-Kiosk-Admin: 1 fejléccel.
# A PIN után a GitHubon lévő karikar/kiosk/allowlist.json szerkeszthető:
#   POST /auth   {pin}                  - PIN ellenőrzés
#   POST /config  {pin}                 - aktuális allowlist + meta
#   POST /save    {pin, config}         - mentés GitHubra (write token)
#   POST /power   {pin, action}         - reboot / poweroff
#   POST /update  {pin, action}         - check (frissítés keresése) / start
#   GET  /version                       - telepített verzió + frissítés állapota
#
# A tokenek root-only fájlokban vannak; a böngésző soha nem látja őket.
# =============================================================================
import base64
import glob
import hashlib
import hmac
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from html.parser import HTMLParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"
PORT = int(os.environ.get("ADMIN_UI_PORT", "8878") or "8878")
PIN_FILE = os.environ.get("ADMIN_PIN_FILE", "/etc/kiosk/admin.pin")
ADMIN_HTML = os.environ.get("ADMIN_HTML_FILE", "/usr/share/kiosk/web/admin.html")
UNLOCK_HTML = os.environ.get("UNLOCK_HTML_FILE", "/usr/share/kiosk/web/unlock.html")
THEME_JS = os.environ.get("THEME_JS_FILE", "/usr/share/kiosk/web/theme.js")
THEME_STATE = os.environ.get("KIOSK_THEME_FILE", "/var/lib/kiosk/state/theme")
VERSION_FILE = os.environ.get("KIOSK_VERSION_FILE", "/usr/share/kiosk/VERSION")
UPDATE_STATUS_FILE = os.environ.get("KIOSK_UPDATE_STATUS_FILE", "/var/lib/kiosk/state/update-status")
RENDER = os.environ.get("KIOSK_RENDER", "/usr/local/bin/kiosk-render.sh")
BYPASS_FILE = os.environ.get("KIOSK_BYPASS_FILE", "/run/kiosk/proxy-bypass")
try:
    BYPASS_MINUTES = int(os.environ.get("ADMIN_BYPASS_MINUTES", "15") or "15")
except ValueError:
    BYPASS_MINUTES = 15
BYPASS_MINUTES = max(1, min(BYPASS_MINUTES, 240))

GITHUB_OWNER = os.environ.get("GITHUB_OWNER", "karikar")
GITHUB_REPO = os.environ.get("GITHUB_REPO", "kiosk")
GITHUB_REF = os.environ.get("GITHUB_REF", "main")
GITHUB_PATH = os.environ.get("GITHUB_PATH", "allowlist.json")
GITHUB_TOKEN_FILE = os.environ.get("GITHUB_TOKEN_FILE", "/etc/kiosk/github.token")
GITHUB_WRITE_TOKEN_FILE = os.environ.get(
    "GITHUB_WRITE_TOKEN_FILE", "/etc/kiosk/github-write.token"
)
SYNC_SCRIPT = os.environ.get("KIOSK_SYNC", "/usr/local/bin/kiosk-sync.sh")

TEST_CONFIG = os.environ.get("KIOSK_ADMIN_TEST_CONFIG", "")
TEST_SAVE = os.environ.get("KIOSK_ADMIN_TEST_SAVE", "")
TEST_DISCOVER = os.environ.get("KIOSK_ADMIN_TEST_DISCOVER_FILE", "")
TEST_SKIP_POWER = os.environ.get("KIOSK_ADMIN_TEST_SKIP_POWER") == "1"
UPDATE_SCRIPT = os.environ.get("KIOSK_UPDATE_SCRIPT", "/usr/local/bin/kiosk-update.sh")
UPDATE_EXIT_NEWER = 10
TEST_SKIP_UPDATE = os.environ.get("KIOSK_ADMIN_TEST_SKIP_UPDATE") == "1"
_test_check_rc = os.environ.get("KIOSK_ADMIN_TEST_UPDATE_CHECK_RC", "")
TEST_UPDATE_CHECK_RC = int(_test_check_rc) if _test_check_rc.isdigit() else None
TEST_SKIP_SYNC = os.environ.get("KIOSK_ADMIN_TEST_SKIP_SYNC") == "1"
TEST_SKIP_RENDER = os.environ.get("KIOSK_ADMIN_TEST_SKIP_RENDER") == "1"
TEST_SKIP_DOCS = os.environ.get("KIOSK_ADMIN_TEST_SKIP_DOCS") == "1"
DOCS_DIR = os.environ.get("KIOSK_DOCS_DIR", "/srv/kiosk/docs")
INBOX_DIR = os.environ.get("KIOSK_INBOX_DIR", "/srv/kiosk/inbox")
DOCS_SCRIPT = os.environ.get("KIOSK_DOCS_SCRIPT", "/usr/local/bin/kiosk-docs.sh")
KIOSK_USER = os.environ.get("KIOSK_USER", "kiosk")
MAX_DOC_UPLOAD = 512 * 1024 * 1024

MAX_URL = 2048
MAX_BODY = 2 * 1024 * 1024
MAX_SITES = 300
MAX_EXTRA = 300
MAX_HIDDEN = 300
MAX_DISCOVER_BYTES = 2 * 1024 * 1024
MAX_DISCOVER_CSS = 8
MAX_DISCOVER_DOMAINS = 100
DISCOVER_TIMEOUT = 15
PIN_FAIL_WINDOW = 60.0
PIN_MAX_FAILS = 5

NOISE_HOSTS = {
    "w3.org",
    "schema.org",
    "purl.org",
    "xmlns.com",
    "ogp.me",
    "localhost",
    "127.0.0.1",
    "::1",
}

ABS_URL_RE = re.compile(r"https?://[^\s\"'<>]+", re.I)
CSS_URL_RE = re.compile(r"url\(\s*[\"']?([^\"')\s]+)", re.I)
CSS_IMPORT_RE = re.compile(r"@import\s+(?:url\()?[\"']?([^\"')\s;]+)", re.I)

API_URL = "https://api.github.com/repos/%s/%s/contents/%s" % (
    GITHUB_OWNER,
    GITHUB_REPO,
    urllib.parse.quote(GITHUB_PATH, safe="/"),
)

_LOCK = threading.Lock()
_PIN_FAILS = []


class AdminError(Exception):
    pass


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return handle.read()
    except OSError:
        return ""


def read_token(path):
    return read_text(path).strip()


def write_json(path, data):
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def extract_host(url):
    """URL-ből host; csupasz domain is elfogadható. Érvénytelen -> ''."""
    value = (url or "").strip()
    if not value or len(value) > MAX_URL:
        return ""
    if "://" in value and not re.match(r"^https?://", value, re.I):
        return ""
    if re.match(r"^https?://", value, re.I):
        try:
            parsed = urllib.parse.urlparse(value)
        except ValueError:
            return ""
        if parsed.username or parsed.password:
            return ""
        host = (parsed.hostname or "").lower()
    else:
        bare = value.split("/", 1)[0].split("?", 1)[0].split("#", 1)[0]
        if "@" in bare:
            bare = bare.rsplit("@", 1)[1]
        host = bare.split(":", 1)[0].lower()
    host = host.rstrip(".")
    if host.startswith("www."):
        host = host[4:]
    if not host or not re.match(r"^[a-z0-9*][a-z0-9.*-]*$", host):
        return ""
    return host


def valid_domain(value):
    value = (value or "").strip().lower()
    if not value or len(value) > 253:
        return ""
    if not re.match(r"^[a-z0-9*][a-z0-9.*-]*$", value):
        return ""
    return value


def valid_resolution(value):
    value = (value or "").strip()
    if value == "":
        return ""
    if not re.match(r"^[0-9]{3,4}x[0-9]{3,4}$", value):
        return ""
    return value


def url_key(value):
    return (value or "").strip().lower().rstrip("/")


def domain_covers(source, blocked):
    source = (source or "").strip().lower()
    if source.startswith("*."):
        return blocked.endswith("." + source[2:])
    return blocked == source or blocked.endswith("." + source)


def read_pin_hash():
    return read_text(PIN_FILE).strip()


def pin_configured():
    parts = read_pin_hash().split(":")
    return len(parts) == 3 and parts[0] == "sha256"


def pin_ok(pin):
    parts = read_pin_hash().split(":")
    if len(parts) != 3 or parts[0] != "sha256":
        return False
    candidate = hashlib.sha256((parts[1] + (pin or "")).encode("utf-8")).hexdigest()
    return hmac.compare_digest(parts[2], candidate)


def rate_limited():
    now = time.time()
    with _LOCK:
        _PIN_FAILS[:] = [t for t in _PIN_FAILS if now - t < PIN_FAIL_WINDOW]
        return len(_PIN_FAILS) >= PIN_MAX_FAILS


def note_failure():
    with _LOCK:
        _PIN_FAILS.append(time.time())


def clear_failures():
    with _LOCK:
        _PIN_FAILS.clear()


def gh_request(method, url, token, payload=None):
    data = None
    headers = {
        "Authorization": "Bearer " + token,
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "debian-kiosk-admin/2",
    }
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read().decode("utf-8", "replace")
            try:
                return response.status, json.loads(body) if body else {}
            except json.JSONDecodeError:
                return response.status, {"message": body[:300]}
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        try:
            parsed = json.loads(body) if body else {}
        except json.JSONDecodeError:
            parsed = {"message": body[:300]}
        return exc.code, parsed
    except Exception as exc:  # noqa: BLE001
        return 0, {"message": str(exc)}


def github_error(payload):
    message = ""
    if isinstance(payload, dict):
        message = str(payload.get("message", ""))
    return message[:300] or "ismeretlen GitHub hiba"


def fetch_github():
    tokens = []
    for path in (GITHUB_WRITE_TOKEN_FILE, GITHUB_TOKEN_FILE):
        token = read_token(path)
        if token and token not in tokens:
            tokens.append(token)
    if not tokens:
        raise AdminError(
            "Nincs GitHub token. Állítsd be a /etc/kiosk/github.token fájlt."
        )

    url = API_URL + "?ref=" + urllib.parse.quote(GITHUB_REF, safe="")
    last_error = "ismeretlen GitHub hiba"
    payload = {}
    for token in tokens:
        status, response = gh_request("GET", url, token)
        if status == 200:
            payload = response
            break
        last_error = "GitHub hiba (HTTP %s): %s" % (status, github_error(response))
    else:
        raise AdminError(last_error)

    if not isinstance(payload, dict):
        raise AdminError("A GitHub válasz nem objektum.")
    content = payload.get("content", "")
    if payload.get("encoding") != "base64" or not content:
        raise AdminError("A GitHub nem adott vissza base64 tartalmat.")
    try:
        raw = base64.b64decode(content).decode("utf-8")
        config = json.loads(raw)
    except Exception as exc:  # noqa: BLE001
        raise AdminError("A letöltött allowlist nem érvényes JSON: %s" % exc)
    return config, str(payload.get("sha", ""))


def norm_host(value):
    host = (value or "").strip().lower().rstrip(".")
    if host.startswith("www."):
        host = host[4:]
    return host


def same_site(host, site_host):
    h = norm_host(host)
    s = norm_host(site_host)
    if not h or not s:
        return False
    return h == s or h.endswith("." + s) or s.endswith("." + h)


class AssetParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.urls = set()
        self.css = set()
        self.in_script = 0
        self.in_style = 0

    def add(self, value):
        value = (value or "").strip()
        if value:
            self.urls.add(value)

    def add_css(self, text):
        text = text or ""
        for match in CSS_URL_RE.finditer(text):
            self.add(match.group(1).strip("\"'"))
        for match in CSS_IMPORT_RE.finditer(text):
            self.add(match.group(1).strip("\"'"))

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        a = {key.lower(): (value or "") for key, value in attrs}
        if tag == "script":
            if a.get("src"):
                self.add(a["src"])
            self.in_script += 1
        elif tag == "style":
            self.in_style += 1
        elif tag == "link":
            href = a.get("href", "")
            if href:
                self.add(href)
                rel = a.get("rel", "").lower()
                if "stylesheet" in rel or href.split("?")[0].lower().endswith(".css"):
                    self.css.add(href)
        elif tag in ("img", "source"):
            for key in ("src", "data-src", "data-url", "data-original"):
                if a.get(key):
                    self.add(a[key])
            if a.get("srcset"):
                for part in a["srcset"].split(","):
                    candidate = part.strip().split(" ")[0]
                    if candidate:
                        self.add(candidate)
        elif tag in ("iframe", "embed", "track", "audio", "video", "input"):
            for key in ("src", "poster", "data-src", "data-url"):
                if a.get(key):
                    self.add(a[key])
        elif tag == "object":
            if a.get("data"):
                self.add(a["data"])
        elif tag == "form":
            if a.get("action"):
                self.add(a["action"])
        elif tag == "use":
            for key in ("href", "xlink:href"):
                if a.get(key):
                    self.add(a[key])
        elif tag == "base":
            if a.get("href"):
                self.add(a["href"])
        elif tag == "meta":
            prop = (a.get("property") or a.get("name") or "").lower()
            if prop in ("og:image", "twitter:image") and a.get("content"):
                self.add(a["content"])
        if a.get("style"):
            self.add_css(a["style"])

    def handle_endtag(self, tag):
        tag = tag.lower()
        if tag == "script" and self.in_script > 0:
            self.in_script -= 1
        elif tag == "style" and self.in_style > 0:
            self.in_style -= 1

    def handle_data(self, data):
        if self.in_script:
            for match in ABS_URL_RE.finditer(data):
                self.add(match.group(0))
        if self.in_style:
            self.add_css(data)


def discover_fetch(url, timeout=DISCOVER_TIMEOUT):
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "hu,en;q=0.8",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            final_url = response.geturl()
            charset = response.headers.get_content_charset() or "utf-8"
            raw = response.read(MAX_DISCOVER_BYTES + 1)
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403, 429):
            raise AdminError(
                "A céloldal HTTP %s-at adott (botvédelem/Cloudflare). "
                "A szerveroldali domainkeresés nem tud a challenge-en átmenni; "
                "használd a böngésző forrását, vagy vedd fel kézzel az Extra domaineket."
                % exc.code
            )
        raise AdminError("A céloldal HTTP %s hibát adott." % exc.code)
    except Exception as exc:  # noqa: BLE001
        raise AdminError("A céloldal nem érhető el: %s" % exc)
    if len(raw) > MAX_DISCOVER_BYTES:
        raw = raw[:MAX_DISCOVER_BYTES]
    try:
        text = raw.decode(charset, "replace")
    except LookupError:
        text = raw.decode("utf-8", "replace")
    return text, final_url


def discover_site(url):
    value = (url or "").strip()
    if not re.match(r"^https?://", value, re.I):
        raise AdminError("A külső domainek kereséséhez teljes http(s) cím kell.")
    parsed = urllib.parse.urlparse(value)
    if parsed.username or parsed.password or not parsed.hostname:
        raise AdminError("Érvénytelen cím.")
    site_host = norm_host(parsed.hostname)
    if TEST_DISCOVER:
        html = read_text(TEST_DISCOVER)
        final_url = value
    else:
        html, final_url = discover_fetch(value)

    parser = AssetParser()
    try:
        parser.feed(html)
        parser.close()
    except Exception:  # noqa: BLE001
        pass

    counts = Counter()
    samples = {}

    def consider(raw, base):
        raw = (raw or "").strip()
        if not raw or raw.startswith("#"):
            return
        if raw.startswith("//"):
            raw = "https:" + raw
        if re.match(r"^(data|blob|javascript|mailto|tel):", raw, re.I):
            return
        try:
            absolute = urllib.parse.urljoin(base, raw)
        except ValueError:
            return
        parsed_asset = urllib.parse.urlparse(absolute)
        if parsed_asset.scheme.lower() not in ("http", "https"):
            return
        host = norm_host(parsed_asset.hostname)
        if not host or ":" in host or host in NOISE_HOSTS:
            return
        if same_site(host, site_host):
            return
        if "." not in host:
            return
        counts[host] += 1
        bucket = samples.setdefault(host, [])
        if len(bucket) < 3:
            bucket.append(absolute[:300])

    for raw in parser.urls:
        consider(raw, final_url)

    css_urls = []
    for raw in list(parser.css)[:MAX_DISCOVER_CSS]:
        absolute = urllib.parse.urljoin(final_url, raw)
        if absolute.startswith(("http://", "https://")):
            css_urls.append(absolute)

    if not TEST_DISCOVER:
        deadline = time.time() + 20
        for css_url in css_urls:
            if time.time() > deadline:
                break
            try:
                css_text, css_final = discover_fetch(css_url, timeout=6)
            except AdminError:
                continue
            for match in CSS_URL_RE.finditer(css_text):
                consider(match.group(1).strip("\"'"), css_final)
            for match in CSS_IMPORT_RE.finditer(css_text):
                consider(match.group(1).strip("\"'"), css_final)

    domains = []
    for host, count in sorted(counts.items(), key=lambda item: item[0])[:MAX_DISCOVER_DOMAINS]:
        domains.append(
            {
                "domain": host,
                "count": count,
                "samples": samples.get(host, []),
            }
        )
    return {"site": site_host, "url": final_url, "domains": domains}


def docs_safe_name(name):
    value = urllib.parse.unquote(str(name or "")).strip()
    value = value.replace("\\", "/")
    base = os.path.basename(value)
    if base in ("", ".", "..", "index.html", ".origins") or "\x00" in base:
        return ""
    if len(base) > 180:
        return ""
    return base


def docs_entries():
    entries = []
    try:
        names = os.listdir(DOCS_DIR)
    except OSError:
        return entries
    for name in names:
        if name.startswith(".") or name in ("index.html",):
            continue
        path = os.path.join(DOCS_DIR, name)
        try:
            stat = os.stat(path)
        except OSError:
            continue
        if not os.path.isfile(path):
            continue
        entries.append(
            {
                "name": name,
                "size": stat.st_size,
                "mtime": int(stat.st_mtime),
            }
        )
    entries.sort(key=lambda item: item["name"].lower())
    return entries


def inbox_entries():
    entries = []
    try:
        names = os.listdir(INBOX_DIR)
    except OSError:
        return entries
    for name in names:
        if name.startswith("."):
            continue
        path = os.path.join(INBOX_DIR, name)
        try:
            stat = os.stat(path)
        except OSError:
            continue
        if not os.path.isfile(path):
            continue
        entries.append(
            {
                "name": name,
                "size": stat.st_size,
                "mtime": int(stat.st_mtime),
            }
        )
    entries.sort(key=lambda item: item["name"].lower())
    return entries


def run_docs_script():
    if TEST_SKIP_DOCS:
        return True, ""
    if not os.path.isfile(DOCS_SCRIPT) or not os.access(DOCS_SCRIPT, os.X_OK):
        return False, "a kiosk-docs.sh nem található"
    cmd = [DOCS_SCRIPT]
    if os.geteuid() == 0:
        try:
            import pwd
            pwd.getpwnam(KIOSK_USER)
        except Exception:  # noqa: BLE001
            pass
        else:
            runuser = shutil.which("runuser") or "/usr/sbin/runuser"
            if os.path.exists(runuser):
                cmd = [runuser, "-u", KIOSK_USER, "--", DOCS_SCRIPT]
    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=300,
            check=False,
        )
    except Exception as exc:  # noqa: BLE001
        return False, "a dokumentumfeldolgozó nem futott le: %s" % exc
    if proc.returncode != 0:
        detail = (proc.stdout or "").strip().splitlines()
        return False, detail[-1] if detail else "a dokumentumfeldolgozó hibát adott"
    return True, ""


def version_snapshot():
    """Telepített programverzió + az önfrissítő utolsó állapota."""
    info = {"version": "", "latest": "", "result": "", "checked": ""}
    try:
        with open(VERSION_FILE, "r", encoding="utf-8") as handle:
            info["version"] = handle.read().strip()[:32]
    except OSError:
        pass
    try:
        with open(UPDATE_STATUS_FILE, "r", encoding="utf-8") as handle:
            for line in handle:
                key, sep, value = line.strip().partition("=")
                if sep and key in ("latest", "result", "checked"):
                    info[key] = value[:64]
    except OSError:
        pass
    return info


def read_ui_theme():
    try:
        with open(THEME_STATE, "r", encoding="utf-8") as handle:
            value = handle.read().strip()
    except OSError:
        return "light"
    return "dark" if value == "dark" else "light"


def write_ui_theme(value):
    theme = "dark" if value == "dark" else "light"
    directory = os.path.dirname(THEME_STATE)
    if directory:
        os.makedirs(directory, exist_ok=True)
    tmp = THEME_STATE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(theme + "\n")
    os.replace(tmp, THEME_STATE)
    return theme


def validate_config(raw):
    errors = []
    if not isinstance(raw, dict):
        return ["A konfiguráció nem JSON objektum."]

    start = raw.get("start_url")
    if not isinstance(start, str) or not start.strip():
        errors.append("A start_url kötelező.")
    elif not re.match(r"^https?://", start.strip(), re.I) or not extract_host(start):
        errors.append("A start_url érvénytelen (http:// vagy https:// kell).")
    elif len(start.strip()) > MAX_URL:
        errors.append("A start_url túl hosszú.")

    sites = raw.get("sites")
    site_keys = set()
    blocked_hosts = set()
    allowed_hosts = set()
    if not isinstance(sites, list):
        errors.append("A sites egy lista legyen.")
    elif not (1 <= len(sites) <= MAX_SITES):
        errors.append("A sites 1 és %d közötti elemszámú legyen." % MAX_SITES)
    else:
        for index, site in enumerate(sites, 1):
            if not isinstance(site, dict):
                errors.append("A(z) %d. oldal nem objektum." % index)
                continue
            title = site.get("title")
            url = site.get("url")
            if not isinstance(title, str) or not (1 <= len(title.strip()) <= 80):
                errors.append("A(z) %d. oldal címe 1-80 karakter legyen." % index)
            if not isinstance(url, str) or not re.match(r"^https?://", url.strip(), re.I):
                errors.append("A(z) %d. oldal webcíme érvénytelen." % index)
                continue
            if len(url.strip()) > MAX_URL or not extract_host(url):
                errors.append("A(z) %d. oldal webcíme érvénytelen." % index)
                continue
            allowed = site.get("allowed", True)
            if not isinstance(allowed, bool):
                errors.append("A(z) %d. oldal 'allowed' mezője igaz/hamis legyen." % index)
            key = url_key(url)
            if key in site_keys:
                errors.append("A(z) %d. oldal webcíme duplikált." % index)
            site_keys.add(key)
            host = extract_host(url)
            if allowed is False:
                blocked_hosts.add(host)
            else:
                allowed_hosts.add(host)

    extra = raw.get("extra_domains", [])
    if not isinstance(extra, list):
        errors.append("Az extra_domains egy lista legyen.")
    elif len(extra) > MAX_EXTRA:
        errors.append("Az extra_domains legfeljebb %d elemű lehet." % MAX_EXTRA)
    else:
        seen_extra = set()
        for index, domain in enumerate(extra, 1):
            value = valid_domain(domain) if isinstance(domain, str) else ""
            if not value:
                errors.append("A(z) %d. extra domain érvénytelen." % index)
                continue
            if value in seen_extra:
                errors.append("A(z) %d. extra domain duplikált." % index)
            seen_extra.add(value)
            allowed_hosts.add(value)

    hidden = raw.get("hidden_urls", [])
    hidden_keys = set()
    if not isinstance(hidden, list):
        errors.append("A hidden_urls egy lista legyen.")
    elif len(hidden) > MAX_HIDDEN:
        errors.append("A hidden_urls legfeljebb %d elemű lehet." % MAX_HIDDEN)
    else:
        for index, item in enumerate(hidden, 1):
            if isinstance(item, str):
                url = item.strip()
                title = ""
            elif isinstance(item, dict):
                url = item.get("url", "")
                title = item.get("title", "")
                if not isinstance(url, str):
                    errors.append("A(z) %d. rejtett URL érvénytelen." % index)
                    continue
                if title is None:
                    title = ""
                if not isinstance(title, str):
                    errors.append("A(z) %d. rejtett cím érvénytelen." % index)
                    continue
                if len(title.strip()) > 80:
                    errors.append("A(z) %d. rejtett cím legfeljebb 80 karakter." % index)
            else:
                errors.append("A(z) %d. rejtett elem string vagy objektum legyen." % index)
                continue
            if not url.strip() or len(url.strip()) > MAX_URL or not extract_host(url):
                errors.append("A(z) %d. rejtett URL érvénytelen." % index)
                continue
            key = url_key(url)
            if key in hidden_keys:
                errors.append("A(z) %d. rejtett URL duplikált." % index)
            if key in site_keys:
                errors.append("A(z) %d. rejtett URL már szerepel a weboldalak között." % index)
            hidden_keys.add(key)
            allowed_hosts.add(extract_host(url))

    for blocked in sorted(blocked_hosts):
        for source in sorted(allowed_hosts):
            if domain_covers(source, blocked):
                errors.append(
                    "A(z) %s tiltott oldal domainjét a(z) %s engedélyezés felülírja; "
                    "a proxy domain szinten nem tud kivételt. Távolítsd el az ütközést."
                    % (blocked, source)
                )
                break

    if not allowed_hosts:
        errors.append(
            "Legalább egy engedélyezett domain kell; ha minden oldal tiltott, "
            "a proxy allowlist üres lenne."
        )

    refresh = raw.get("refresh_interval_seconds", 300)
    if (
        not isinstance(refresh, int)
        or isinstance(refresh, bool)
        or refresh < 30
        or refresh > 86400
    ):
        errors.append("A refresh_interval_seconds 30 és 86400 közötti egész legyen.")

    resolution = raw.get("resolution", "")
    if not isinstance(resolution, str):
        errors.append("A felbontás szöveg legyen (pl. 1366x768).")
    elif resolution.strip() and not valid_resolution(resolution):
        errors.append("A felbontás formátuma ilyen legyen: 1366x768 (vagy üres).")

    return errors


def normalize_config(raw):
    sites = []
    for site in raw.get("sites", []):
        entry = {
            "title": str(site.get("title", "")).strip(),
            "url": str(site.get("url", "")).strip(),
        }
        if site.get("allowed", True) is False:
            entry["allowed"] = False
        sites.append(entry)
    extra = []
    for domain in raw.get("extra_domains", []):
        value = valid_domain(domain) if isinstance(domain, str) else ""
        if value:
            extra.append(value)
    hidden = []
    for item in raw.get("hidden_urls", []):
        if isinstance(item, str):
            value = item.strip()
            if value:
                hidden.append(value)
        elif isinstance(item, dict):
            url = str(item.get("url", "")).strip()
            title = str(item.get("title") or "").strip()
            if not url:
                continue
            hidden.append({"title": title, "url": url} if title else url)
    return {
        "start_url": str(raw.get("start_url", "")).strip(),
        "sites": sites,
        "extra_domains": extra,
        "hidden_urls": hidden,
        "refresh_interval_seconds": int(raw.get("refresh_interval_seconds", 300)),
        "resolution": valid_resolution(str(raw.get("resolution", ""))),
    }


def save_github(config):
    token = read_token(GITHUB_WRITE_TOKEN_FILE)
    if not token:
        raise AdminError(
            "Nincs írásjogú GitHub token (/etc/kiosk/github-write.token). "
            "Hozz létre egy Contents: Read and write tokent, majd futtasd: "
            "kiosk-admin.sh set-write-token"
        )
    _current, sha = fetch_github()
    body = json.dumps(config, ensure_ascii=False, indent=2) + "\n"
    payload = {
        "message": "Admin felület: allowlist frissítése",
        "content": base64.b64encode(body.encode("utf-8")).decode("ascii"),
        "branch": GITHUB_REF,
    }
    if sha:
        payload["sha"] = sha
    status, response = gh_request("PUT", API_URL, token, payload)
    if status not in (200, 201):
        raise AdminError(
            "A GitHub mentés nem sikerült (HTTP %s): %s"
            % (status, github_error(response))
        )


def trigger_sync():
    if TEST_SKIP_SYNC:
        return
    try:
        if os.path.exists(SYNC_SCRIPT):
            subprocess.Popen(
                [SYNC_SCRIPT],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        else:
            subprocess.Popen(
                ["systemctl", "start", "kiosk-sync.service"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
    except Exception:  # noqa: BLE001
        pass


# --- ideiglenes proxy-feloldás ---------------------------------------------
def bypass_expiry():
    try:
        return int(read_text(BYPASS_FILE).strip())
    except (TypeError, ValueError):
        return 0


def bypass_snapshot():
    expiry = bypass_expiry()
    remaining = max(0, expiry - int(time.time())) if expiry else 0
    return {
        "active": remaining > 0,
        "remaining": remaining,
        "minutes": BYPASS_MINUTES,
    }


def write_bypass(minutes):
    directory = os.path.dirname(BYPASS_FILE)
    if directory:
        os.makedirs(directory, exist_ok=True)
    expiry = int(time.time()) + max(1, minutes) * 60
    tmp = BYPASS_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(str(expiry) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(tmp, 0o600)
    os.replace(tmp, BYPASS_FILE)


def remove_bypass():
    try:
        os.remove(BYPASS_FILE)
    except OSError:
        pass


def apply_proxy_mode():
    if TEST_SKIP_RENDER:
        return True, ""
    env = dict(os.environ)
    env["KIOSK_NO_RELOAD"] = "1"
    try:
        result = subprocess.run(
            [RENDER], env=env, capture_output=True, text=True, timeout=90
        )
    except Exception as exc:  # noqa: BLE001
        return False, str(exc)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        return False, detail[-300:]
    try:
        subprocess.run(
            ["systemctl", "try-restart", "kiosk-proxy.service"],
            capture_output=True,
            timeout=30,
        )
    except Exception:  # noqa: BLE001
        pass
    return True, ""


def lock_proxy():
    remove_bypass()
    return apply_proxy_mode()


def bypass_watch():
    # A lejárat után a szolgáltatás visszazárja a proxyt, akkor is, ha
    # közben nem futott szinkron.
    while True:
        time.sleep(5)
        if bypass_expiry() and bypass_snapshot()["active"] is False:
            lock_proxy()


def power_action(action):
    if action not in ("reboot", "poweroff"):
        raise AdminError("Ismeretlen művelet.")
    if TEST_SKIP_POWER:
        return
    try:
        result = subprocess.run(
            ["systemctl", action], capture_output=True, text=True, timeout=20
        )
    except Exception as exc:  # noqa: BLE001
        raise AdminError("A művelet nem indult el: %s" % exc)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        raise AdminError("A művelet nem sikerült: %s" % (detail[-200:] or "ismeretlen hiba"))


def update_action(action):
    """Programfrissítés: "check" = keresés, "start" = frissítés azonnal.

    A frissítést külön, átmeneti systemd unitban indítjuk (systemd-run):
    a telepítő ezt a szolgáltatást is újraindítja, és a frissítésnek ezt
    túl kell élnie. A --now kapcsoló a karbantartási ablakot figyelmen
    kívül hagyja (a gombnyomás kifejezett kérés).
    """
    if action == "check":
        if TEST_UPDATE_CHECK_RC is not None:
            rc, out, err = TEST_UPDATE_CHECK_RC, "Teszt: új verzió", ""
        else:
            try:
                proc = subprocess.run(
                    [UPDATE_SCRIPT, "--check"], capture_output=True, text=True, timeout=120
                )
            except Exception as exc:  # noqa: BLE001
                raise AdminError("A frissítés keresése nem indult el: %s" % exc)
            rc, out, err = proc.returncode, proc.stdout or "", proc.stderr or ""
        if rc not in (0, UPDATE_EXIT_NEWER):
            lines = [line for line in err.strip().splitlines() if line.strip()]
            detail = lines[-1] if lines else "ismeretlen hiba"
            # "2026-11-25 12:00:00 [ERROR] ..." -> csak az üzenet
            detail = re.sub(r"^\S+ \S+ \[\w+\s*\]\s*", "", detail)
            raise AdminError("A frissítés keresése nem sikerült: %s" % detail[-300:])
        message = (out.strip().splitlines() or [""])[-1]
        return dict(version_snapshot(), available=(rc == UPDATE_EXIT_NEWER), message=message)

    if action == "start":
        if not TEST_SKIP_UPDATE:
            unit = "kiosk-update-now-%d" % int(time.time())
            try:
                proc = subprocess.run(
                    ["systemd-run", "--unit=" + unit, "--no-block", "--collect", "--quiet",
                     "--description=Kiosk programfrissítés (admin felület)",
                     UPDATE_SCRIPT, "--now"],
                    capture_output=True, text=True, timeout=20,
                )
            except Exception as exc:  # noqa: BLE001
                raise AdminError("A frissítés nem indult el: %s" % exc)
            if proc.returncode != 0:
                detail = (proc.stderr or proc.stdout or "").strip()
                raise AdminError("A frissítés nem indult el: %s" % (detail[-200:] or "ismeretlen hiba"))
        return dict(version_snapshot(), started=True)

    raise AdminError("Ismeretlen művelet.")


def config_meta():
    return {
        "owner": GITHUB_OWNER,
        "repo": GITHUB_REPO,
        "path": GITHUB_PATH,
        "ref": GITHUB_REF,
        "has_write_token": bool(read_token(GITHUB_WRITE_TOKEN_FILE)),
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "KioskAdmin/2.0"

    def log_message(self, fmt, *args):  # noqa: A003
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

    def _cors(self):
        origin = self.headers.get("Origin")
        if origin in (None, "", "null"):
            self.send_header("Access-Control-Allow-Origin", "null")
            self.send_header("Vary", "Origin")

    def _json(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self._cors()
        self.end_headers()
        self.wfile.write(body)

    def _api_request(self):
        return self.headers.get("X-Kiosk-Admin") == "1"

    def _body(self):
        try:
            length = int(self.headers.get("Content-Length", "0") or "0")
        except ValueError:
            return None
        if length <= 0 or length > MAX_BODY:
            return None
        try:
            return json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception:  # noqa: BLE001
            return None

    def _docs_upload(self):
        pin = str(self.headers.get("X-Kiosk-PIN", ""))
        if rate_limited():
            return self._json(429, {"ok": False, "error": "túl sok próbálkozás, várj egy percet"})
        if not pin_configured():
            return self._json(503, {"ok": False, "error": "nincs beállítva admin PIN"})
        if not pin_ok(pin):
            note_failure()
            return self._json(403, {"ok": False, "error": "rossz PIN"})
        clear_failures()

        name = docs_safe_name(self.headers.get("X-Kiosk-Filename", ""))
        if not name:
            return self._json(400, {"ok": False, "error": "érvénytelen fájlnév"})
        try:
            length = int(self.headers.get("Content-Length", "0") or "0")
        except ValueError:
            length = 0
        if length <= 0:
            return self._json(400, {"ok": False, "error": "üres feltöltés"})
        if length > MAX_DOC_UPLOAD:
            return self._json(
                413,
                {"ok": False, "error": "a fájl legfeljebb %d MB lehet" % (MAX_DOC_UPLOAD // 1048576)},
            )

        try:
            os.makedirs(INBOX_DIR, exist_ok=True)
        except OSError as exc:
            return self._json(500, {"ok": False, "error": "az inbox nem hozható létre: %s" % exc})

        stem, ext = os.path.splitext(name)
        target = os.path.join(INBOX_DIR, name)
        counter = 1
        while os.path.exists(target):
            target = os.path.join(INBOX_DIR, "%s-%d%s" % (stem, counter, ext))
            counter += 1
            if counter > 1000:
                return self._json(500, {"ok": False, "error": "nem található szabad fájlnév"})

        tmp = target + ".part"
        try:
            remaining = length
            with open(tmp, "wb") as handle:
                while remaining > 0:
                    chunk = self.rfile.read(min(65536, remaining))
                    if not chunk:
                        raise OSError("a feltöltés megszakadt")
                    handle.write(chunk)
                    remaining -= len(chunk)
            os.replace(tmp, target)
            try:
                import pwd
                owner = pwd.getpwnam(KIOSK_USER)
                os.chown(target, owner.pw_uid, owner.pw_gid)
                os.chmod(target, 0o644)
            except Exception:  # noqa: BLE001
                pass
        except OSError as exc:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            return self._json(500, {"ok": False, "error": "a feltöltés mentése nem sikerült: %s" % exc})

        ok, detail = run_docs_script()
        if not ok:
            return self._json(
                500,
                {
                    "ok": False,
                    "error": "a fájl bekerült az inboxba, de a feldolgozás nem sikerült: %s" % detail,
                    "name": os.path.basename(target),
                },
            )
        return self._json(
            200,
            {
                "ok": True,
                "name": os.path.basename(target),
                "docs": docs_entries(),
            },
        )

    def do_OPTIONS(self):  # noqa: N802
        self.send_response(204)
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Kiosk-Admin, X-Kiosk-PIN, X-Kiosk-Filename")
        self.send_header("Access-Control-Max-Age", "600")
        self._cors()
        self.end_headers()

    def do_GET(self):  # noqa: N802
        if self.path in ("/", "/index.html"):
            try:
                with open(ADMIN_HTML, "rb") as handle:
                    body = handle.read()
            except OSError:
                return self._json(500, {"ok": False, "error": "az admin oldal nem található"})
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/theme.js":
            try:
                with open(THEME_JS, "rb") as handle:
                    body = handle.read()
            except OSError:
                return self._json(404, {"ok": False, "error": "a téma script nem található"})
            self.send_response(200)
            self.send_header("Content-Type", "application/javascript; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/theme":
            return self._json(200, {"ok": True, "theme": read_ui_theme()})

        if self.path in ("/unlock", "/unlock/") or self.path.startswith("/unlock?"):
            try:
                with open(UNLOCK_HTML, "rb") as handle:
                    body = handle.read()
            except OSError:
                return self._json(500, {"ok": False, "error": "a feloldó oldal nem található"})
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/unlock-status":
            return self._json(200, dict({"ok": True}, **bypass_snapshot()))

        if self.path == "/version":
            return self._json(200, dict({"ok": True}, **version_snapshot()))

        return self._json(404, {"ok": False, "error": "ismeretlen végpont"})

    def do_POST(self):  # noqa: N802
        if self.path == "/theme":
            data = self._body()
            if not isinstance(data, dict) or data.get("theme") not in ("light", "dark"):
                return self._json(400, {"ok": False, "error": "érvénytelen téma"})
            try:
                theme = write_ui_theme(data["theme"])
            except OSError as exc:
                return self._json(500, {"ok": False, "error": "a téma mentése nem sikerült: %s" % exc})
            return self._json(200, {"ok": True, "theme": theme})

        if not self._api_request():
            return self._json(403, {"ok": False, "error": "tiltott kérés"})
        if self.path not in (
            "/auth", "/config", "/save", "/power", "/update", "/unlock", "/lock", "/discover",
            "/docs/list", "/docs/upload", "/docs/delete",
            "/docs/inbox", "/docs/process", "/docs/inbox/delete",
        ):
            return self._json(404, {"ok": False, "error": "ismeretlen végpont"})

        if self.path == "/docs/upload":
            return self._docs_upload()

        data = self._body()
        if not isinstance(data, dict):
            return self._json(400, {"ok": False, "error": "hibás kérés"})

        # A lezárás biztonságos művelet (csak szigorít), ezért PIN nélkül is megy.
        if self.path == "/lock":
            ok, detail = lock_proxy()
            if not ok:
                return self._json(
                    500,
                    {"ok": False, "error": "a proxy visszazárása nem sikerült", "detail": detail},
                )
            return self._json(200, {"ok": True, "active": False, "minutes": BYPASS_MINUTES})

        if rate_limited():
            return self._json(429, {"ok": False, "error": "túl sok próbálkozás, várj egy percet"})
        if not pin_configured():
            return self._json(503, {"ok": False, "error": "nincs beállítva admin PIN"})
        if not pin_ok(str(data.get("pin", ""))):
            note_failure()
            return self._json(403, {"ok": False, "error": "rossz PIN"})
        clear_failures()

        if self.path == "/docs/list":
            return self._json(200, {"ok": True, "docs": docs_entries()})

        if self.path == "/docs/inbox":
            return self._json(200, {"ok": True, "inbox": inbox_entries()})

        if self.path == "/docs/process":
            ok, detail = run_docs_script()
            if not ok:
                return self._json(
                    500,
                    {
                        "ok": False,
                        "error": "a feldolgozás nem sikerült: %s" % detail,
                        "docs": docs_entries(),
                        "inbox": inbox_entries(),
                    },
                )
            return self._json(
                200,
                {"ok": True, "docs": docs_entries(), "inbox": inbox_entries()},
            )

        if self.path == "/docs/inbox/delete":
            name = docs_safe_name(data.get("name", ""))
            if not name:
                return self._json(400, {"ok": False, "error": "érvénytelen fájlnév"})
            path = os.path.join(INBOX_DIR, name)
            if not os.path.isfile(path):
                return self._json(404, {"ok": False, "error": "nincs ilyen beérkező fájl"})
            try:
                os.unlink(path)
            except OSError as exc:
                return self._json(500, {"ok": False, "error": "a törlés nem sikerült: %s" % exc})
            return self._json(200, {"ok": True, "inbox": inbox_entries()})

        if self.path == "/docs/delete":
            name = docs_safe_name(data.get("name", ""))
            if not name:
                return self._json(400, {"ok": False, "error": "érvénytelen fájlnév"})
            path = os.path.join(DOCS_DIR, name)
            if not os.path.isfile(path):
                return self._json(404, {"ok": False, "error": "nincs ilyen dokumentum"})
            try:
                os.unlink(path)
            except OSError as exc:
                return self._json(500, {"ok": False, "error": "a törlés nem sikerült: %s" % exc})

            # A feldolgozott eredetit is töröljük, ha ott maradt.
            for candidate in glob.glob(
                os.path.join(INBOX_DIR, "processed", "*" + glob.escape(name))
            ):
                if os.path.isfile(candidate):
                    try:
                        os.unlink(candidate)
                    except OSError:
                        pass

            # Az .origins nyilvántartásból is kikerül.
            origins = os.path.join(DOCS_DIR, ".origins")
            if os.path.isfile(origins):
                try:
                    with open(origins, "r", encoding="utf-8", errors="replace") as handle:
                        lines = [
                            line for line in handle
                            if not line.startswith(name + "\t")
                        ]
                    with open(origins, "w", encoding="utf-8") as handle:
                        handle.writelines(lines)
                except OSError:
                    pass

            ok, detail = run_docs_script()
            if not ok:
                return self._json(
                    500,
                    {
                        "ok": False,
                        "error": "a fájl törölve, de a lista frissítése nem sikerült: %s" % detail,
                        "docs": docs_entries(),
                    },
                )
            return self._json(200, {"ok": True, "docs": docs_entries()})

        if self.path == "/auth":
            return self._json(200, {"ok": True})

        if self.path == "/discover":
            url = str(data.get("url", "")).strip()
            parsed_url = urllib.parse.urlparse(url)
            if (
                not re.match(r"^https?://", url, re.I)
                or not parsed_url.hostname
                or parsed_url.username
                or parsed_url.password
            ):
                return self._json(400, {"ok": False, "error": "érvénytelen http(s) cím"})
            try:
                result = discover_site(url)
            except AdminError as exc:
                return self._json(502, {"ok": False, "error": str(exc)})
            except Exception as exc:  # noqa: BLE001
                return self._json(502, {"ok": False, "error": "a domainek keresése nem sikerült: %s" % exc})
            return self._json(200, dict({"ok": True}, **result))

        if self.path == "/unlock":
            try:
                write_bypass(BYPASS_MINUTES)
            except OSError as exc:
                return self._json(500, {"ok": False, "error": "a feloldás mentése nem sikerült: %s" % exc})
            ok, detail = apply_proxy_mode()
            if not ok:
                remove_bypass()
                apply_proxy_mode()
                return self._json(
                    500,
                    {"ok": False, "error": "a proxy feloldása nem sikerült", "detail": detail},
                )
            snapshot = bypass_snapshot()
            return self._json(200, dict({"ok": True}, **snapshot))

        if self.path == "/config":
            try:
                if TEST_CONFIG:
                    if TEST_SAVE and os.path.exists(TEST_SAVE):
                        config = json.loads(read_text(TEST_SAVE))
                    else:
                        config = json.loads(read_text(TEST_CONFIG))
                else:
                    config, _sha = fetch_github()
            except AdminError as exc:
                return self._json(502, {"ok": False, "error": str(exc)})
            except Exception as exc:  # noqa: BLE001
                return self._json(502, {"ok": False, "error": "a konfiguráció nem olvasható: %s" % exc})
            return self._json(200, {"ok": True, "config": config, "meta": config_meta()})

        if self.path == "/save":
            config = data.get("config")
            errors = validate_config(config)
            if errors:
                return self._json(
                    400,
                    {"ok": False, "error": errors[0], "errors": errors},
                )
            normalized = normalize_config(config)
            try:
                if TEST_SAVE:
                    write_json(TEST_SAVE, normalized)
                else:
                    save_github(normalized)
                    trigger_sync()
            except AdminError as exc:
                return self._json(502, {"ok": False, "error": str(exc)})
            except Exception as exc:  # noqa: BLE001
                return self._json(500, {"ok": False, "error": "mentési hiba: %s" % exc})
            return self._json(
                200,
                {
                    "ok": True,
                    "message": "Mentve. A kiosk a következő frissítéskor (vagy újraindításkor) alkalmazza.",
                    "config": normalized,
                },
            )

        if self.path == "/update":
            try:
                result = update_action(str(data.get("action", "")))
            except AdminError as exc:
                return self._json(500, dict({"ok": False, "error": str(exc)}, **version_snapshot()))
            return self._json(200, dict({"ok": True}, **result))

        action = str(data.get("action", ""))
        try:
            power_action(action)
        except AdminError as exc:
            return self._json(400, {"ok": False, "error": str(exc)})
        return self._json(200, {"ok": True, "action": action})


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "--check-url":
        host = extract_host(sys.argv[2])
        if host:
            print(host)
            return 0
        return 1

    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(
        "Kiosk admin UI: http://%s:%d/ (PIN: %s, write token: %s)"
        % (
            HOST,
            PORT,
            "beállítva" if pin_configured() else "nincs",
            "van" if read_token(GITHUB_WRITE_TOKEN_FILE) else "nincs",
        ),
        flush=True,
    )
    if not TEST_SKIP_RENDER:
        threading.Thread(target=bypass_watch, daemon=True).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
