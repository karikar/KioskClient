#!/usr/bin/env bash
# =============================================================================
# Az összes helyi füstteszt futtatása (root nélkül).
#   tests/run-all.sh
# =============================================================================
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

echo "########## render-smoke ##########"
bash "${ROOT}/tests/render-smoke.sh"
echo
echo "########## docs-smoke ##########"
bash "${ROOT}/tests/docs-smoke.sh"
echo
echo "########## report-smoke ##########"
bash "${ROOT}/tests/report-smoke.sh"
echo
echo "########## admin-ui-test ##########"
bash "${ROOT}/tests/admin-ui-test.sh"
echo
echo "########## update-smoke ##########"
bash "${ROOT}/tests/update-smoke.sh"
