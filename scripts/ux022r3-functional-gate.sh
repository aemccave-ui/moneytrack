#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo '# Phase'
echo 'UX-022R3 functional recovery 1-8'
echo '# Gate'
echo 'READ_ONLY / ROLLBACK_ONLY'

bash scripts/ux022-source-gate.sh
bash scripts/ux022r3-transaction-write-gate.sh
bash scripts/ux022r3-quick-input-forensic.sh

echo 'UX022R3_FUNCTIONAL_PREFLIGHT=COMPLETE'
echo 'PERSISTENT_DB_MUTATION=NONE'
echo 'N8N_MUTATION=NONE'
echo 'PREVIEW_MUTATION=NONE'
echo 'PRODUCTION_FRONTEND_MUTATION=NONE'
