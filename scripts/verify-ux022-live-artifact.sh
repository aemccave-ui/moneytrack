#!/usr/bin/env bash
set -euo pipefail

WORK="/tmp/moneytrack-ux022-balance-fix"
WEBROOT="/var/www/moneytrack-miniapp"
LIVE_ORIGIN="https://app.moneytrackapp.xyz"

fail() {
  echo "VERIFY=FAIL reason=$1"
  exit 1
}

extract_app_asset() {
  local index_file="$1"
  local asset
  asset="$(
    grep -oE 'src="[^"]*assets/[^"]+\.js"' "$index_file" \
      | head -n1 \
      | cut -d'"' -f2
  )"
  [ -n "$asset" ] || return 1
  case "$asset" in
    http://*|https://*) return 1 ;;
    /*) printf '%s\n' "$asset" ;;
    ./*) printf '/%s\n' "${asset#./}" ;;
    *) printf '/%s\n' "$asset" ;;
  esac
}

echo "=== MONEYTRACK FRONTEND ARTIFACT VERIFY ==="

BUILD_INDEX="$WORK/miniapp/dist/index.html"
WEBROOT_INDEX="$WEBROOT/index.html"
LIVE_INDEX="/tmp/moneytrack-live-index.html"
LIVE_BUNDLE="/tmp/moneytrack-live-bundle.js"

[ -f "$BUILD_INDEX" ] || fail "build_index_missing"
[ -f "$WEBROOT_INDEX" ] || fail "webroot_index_missing"

curl -fsS \
  -H 'Cache-Control: no-cache, no-store, must-revalidate' \
  "${LIVE_ORIGIN}/?verify=$(date +%s)" \
  -o "$LIVE_INDEX" \
  || fail "live_index_download"

BUILD_ASSET="$(extract_app_asset "$BUILD_INDEX")" || fail "build_app_asset_not_found"
WEBROOT_ASSET="$(extract_app_asset "$WEBROOT_INDEX")" || fail "webroot_app_asset_not_found"
LIVE_ASSET="$(extract_app_asset "$LIVE_INDEX")" || fail "live_app_asset_not_found"

echo "build_asset=$BUILD_ASSET"
echo "webroot_asset=$WEBROOT_ASSET"
echo "live_asset=$LIVE_ASSET"

BUILD_FILE="$WORK/miniapp/dist/${BUILD_ASSET#/}"
WEBROOT_FILE="$WEBROOT/${WEBROOT_ASSET#/}"

[ -s "$BUILD_FILE" ] || fail "build_bundle_missing"
[ -s "$WEBROOT_FILE" ] || fail "webroot_bundle_missing"

curl -fsS \
  -H 'Cache-Control: no-cache, no-store, must-revalidate' \
  "${LIVE_ORIGIN}${LIVE_ASSET}?verify=$(date +%s)" \
  -o "$LIVE_BUNDLE" \
  || fail "live_bundle_download"

[ -s "$LIVE_BUNDLE" ] || fail "live_bundle_empty"

BUILD_SHA="$(sha256sum "$BUILD_FILE" | awk '{print $1}')"
WEBROOT_SHA="$(sha256sum "$WEBROOT_FILE" | awk '{print $1}')"
LIVE_SHA="$(sha256sum "$LIVE_BUNDLE" | awk '{print $1}')"

[ -n "$BUILD_SHA" ] || fail "build_sha_empty"
[ -n "$WEBROOT_SHA" ] || fail "webroot_sha_empty"
[ -n "$LIVE_SHA" ] || fail "live_sha_empty"

echo "build_sha=$BUILD_SHA"
echo "webroot_sha=$WEBROOT_SHA"
echo "live_sha=$LIVE_SHA"

grep -Fq 'snapshot_missing_rate_count' "$BUILD_FILE" \
  || fail "build_fix_marker_missing"
grep -Fq 'snapshot_missing_rate_count' "$WEBROOT_FILE" \
  || fail "webroot_fix_marker_missing"
grep -Fq 'snapshot_missing_rate_count' "$LIVE_BUNDLE" \
  || fail "live_fix_marker_missing"

echo "build_fix_marker=PASS"
echo "webroot_fix_marker=PASS"
echo "live_fix_marker=PASS"

[ "$BUILD_ASSET" = "$WEBROOT_ASSET" ] \
  || fail "asset_name_build_vs_webroot"
[ "$BUILD_ASSET" = "$LIVE_ASSET" ] \
  || fail "asset_name_build_vs_live"

[ "$BUILD_SHA" = "$WEBROOT_SHA" ] \
  || fail "sha_build_vs_webroot"
[ "$BUILD_SHA" = "$LIVE_SHA" ] \
  || fail "sha_build_vs_live"

echo "artifact_identity=PASS"
echo "VERIFY=PASS"
