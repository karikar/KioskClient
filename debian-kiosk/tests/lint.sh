#!/usr/bin/env bash
# =============================================================================
# Statikus ellenőrzés a projekt scriptjeire (ha a shellcheck telepítve van).
#   tests/lint.sh
# =============================================================================
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

if ! command -v shellcheck >/dev/null 2>&1; then
    echo "shellcheck nincs telepítve - kihagyva (apt install shellcheck)."
    exit 0
fi

rc=0
while IFS= read -r -d '' f; do
    if ! shellcheck -S warning -e SC1091 "$f"; then
        rc=1
    fi
done < <(find . -name '*.sh' -not -path './tests/_*' -print0)

if [ "$rc" = 0 ]; then
    echo "SHELLCHECK: tiszta"
fi
exit "$rc"
