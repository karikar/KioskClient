#!/usr/bin/env bash
# =============================================================================
# Kiadási csomag készítése az önfrissítőnek
#
#   tools/make-release.sh [kimeneti könyvtár]      (alapból: ../dist)
#
# Eredmény:
#   debian-kiosk-<VERSION>.tar.gz          (benne: debian-kiosk-<VERSION>/...)
#   debian-kiosk-<VERSION>.tar.gz.sha256
#
# A GitHub Actions release workflow is ezt hívja; kézzel is futtatható, és a
# két fájl feltölthető a GitHub release-hez csatolmányként.
# =============================================================================
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-${ROOT}/../dist}"
PREFIX="${UPDATE_ASSET_PREFIX:-debian-kiosk}"

version="$(tr -d '[:space:]' <"${ROOT}/VERSION")"
[[ "$version" =~ ^[0-9]+(\.[0-9]+){1,3}(-[0-9A-Za-z.]+)?$ ]] ||
    { echo "Hibás VERSION: '${version}'" >&2; exit 1; }

# Ha tagről fut (CI), a tagnek egyeznie kell a VERSION fájllal.
if [ -n "${RELEASE_TAG:-}" ] && [ "${RELEASE_TAG#v}" != "$version" ]; then
    echo "A tag (${RELEASE_TAG}) nem egyezik a VERSION fájllal (${version})." >&2
    exit 1
fi

name="${PREFIX}-${version}"
mkdir -p "$OUT"
OUT="$(cd -- "$OUT" && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT

mkdir -p "${stage}/${name}"
# Csak a futáshoz és telepítéshez szükséges fájlok; titkok, tesztek nélkül.
tar -C "$ROOT" \
    --exclude='./.git' --exclude='./tests' --exclude='./tools' \
    --exclude='*.token' --exclude='*.pat' --exclude='github.env' \
    --exclude='*.tmp' --exclude='*.log' \
    -cf - . | tar -C "${stage}/${name}" -xf -

# Szintaxis ellenőrzés a csomagolás előtt.
while IFS= read -r -d '' f; do
    bash -n "$f"
done < <(find "${stage}/${name}" -name '*.sh' -type f -print0)

# Jogosultságok: a scriptek futtathatók, minden más 0644.
find "${stage}/${name}" -type d -exec chmod 0755 {} +
find "${stage}/${name}" -type f -exec chmod 0644 {} +
find "${stage}/${name}" -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod 0755 {} +

archive="${OUT}/${name}.tar.gz"
# Reprodukálható archívum (rendezett, fix tulajdonos, fix időbélyeg).
tar -C "$stage" --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime='2000-01-01 00:00:00Z' -cf - "$name" | gzip -n -9 >"$archive"

(cd "$OUT" && sha256sum "${name}.tar.gz" >"${name}.tar.gz.sha256")

echo "Kész: ${archive}"
cat "${archive}.sha256"
