#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo '# Phase'
echo 'UX-022 source/static'
echo '# Gate'
echo 'source_static_lint_build'

python3 scripts/ux022-verify-source.py
python3 -m py_compile scripts/ux022-generate-api-workflows.py scripts/ux022-verify-source.py

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
