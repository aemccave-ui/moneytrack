#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo '# Phase'
echo 'UX-022 source/static'
echo '# Gate'
echo 'source_static_lint_build'

# Syntax validation must run before npm install/build and before any runtime gate.
for shell_script in \
  scripts/ux022-source-gate.sh \
  scripts/ux022-db-runtime.sh \
  scripts/ux022-render-migration.sh \
  scripts/ux022-migration-gate.sh \
  scripts/ux022-deploy-preview.sh \
  scripts/ux022r3-apply-preview.sh \
  scripts/ux022r3-frontend-preview.sh
do
  bash -n "$shell_script"
done

echo 'shell_syntax_validation=PASS'

python3 -m py_compile \
  scripts/ux022-generate-api-workflows.py \
  scripts/ux022-merge-lifecycle-into-presets.py \
  scripts/ux022-runtime-smoke.py \
  scripts/ux022-verify-source.py \
  scripts/ux022r3-verify-grouping.py

python3 scripts/ux022-verify-source.py
python3 scripts/ux022r3-verify-grouping.py

cd miniapp
npm ci
npm run lint
rm -rf dist
npm run build

mapfile -t assets < <(find dist/assets -maxdepth 1 -type f -name '*.js' -print | sort)
if (( ${#assets[@]} == 0 )); then
  echo 'build_artifact_js=FAIL'
  exit 1
fi

artifact="${assets[0]}"
sha="$(sha256sum "$artifact" | awk '{print $1}')"
if [[ -z "$sha" ]]; then
  echo 'build_artifact_sha=FAIL'
  exit 1
fi

echo "build_artifact=$artifact"
echo "build_artifact_sha256=$sha"
echo 'source_static_lint_build=PASS'
