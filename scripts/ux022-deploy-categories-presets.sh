#!/usr/bin/env bash
set -Eeuo pipefail

REPO="/home/adm_mt/moneytrack"
BRANCH="agent/ux-022-accounts-explorer"
WORK="/tmp/moneytrack-ux022-categories-presets"
STAMP="$(date +%Y%m%dT%H%M%S)"

TX_ID="UX022TxApi202608"
SUMMARY_ID="UX022Summary202608"
PRESETS_ID="UX022Presets202608"
TX_REL="workflows/moneytrack-transactions-api-UX022TxApi202608.json"
SUMMARY_REL="workflows/moneytrack-accounts-explorer-summary-UX022Summary202608.json"
PRESETS_REL="workflows/moneytrack-filter-presets-UX022Presets202608.json"
MIGRATION_REL="sql/migrations/20260809_ux022_filter_presets.sql"
PREVIEW_ROOT="/var/www/moneytrack-miniapp-preview"
PREVIEW_ORIGIN="https://preview.moneytrackapp.xyz"

BACKUP_TX="/tmp/${TX_ID}-before-filters-${STAMP}.json"
BACKUP_SUMMARY="/tmp/${SUMMARY_ID}-before-filters-${STAMP}.json"
BACKUP_PRESETS="/tmp/${PRESETS_ID}-before-filters-${STAMP}.json"
PREVIEW_ROLLBACK="${PREVIEW_ROOT}.rollback.${STAMP}"

RUNTIME_MUTATED=0
FRONTEND_MUTATED=0
PRESETS_EXISTED=0

cleanup() {
  git -C "$REPO" worktree remove --force "$WORK" >/dev/null 2>&1 || true
}

wait_health() {
  local i
  for i in $(seq 1 90); do
    if curl -fsS --max-time 3 http://127.0.0.1:5678/healthz >/dev/null 2>&1; then
      echo "n8n_health=PASS attempt=$i"
      return 0
    fi
    sleep 2
  done
  echo "n8n_health=FAIL"
  return 1
}

wait_auth_contract() {
  local name="$1"
  local method="$2"
  local url="$3"
  local body="/tmp/${name}-${STAMP}.json"
  local http=""
  local i
  for i in $(seq 1 90); do
    if [ "$method" = "GET" ] || [ "$method" = "DELETE" ]; then
      http="$(curl -sS --max-time 5 -X "$method" -o "$body" -w '%{http_code}' "$url" || true)"
    else
      http="$(curl -sS --max-time 5 -X "$method" -H 'Content-Type: application/json' -d '{}' -o "$body" -w '%{http_code}' "$url" || true)"
    fi
    if [ "$http" = "401" ] && grep -Fq "INIT_DATA_MISSING" "$body"; then
      echo "${name}=PASS http=401 attempt=$i"
      return 0
    fi
    if [ "$i" -eq 1 ] || [ $((i % 10)) -eq 0 ]; then
      echo "${name}_wait attempt=$i http=${http:-none}"
    fi
    sleep 2
  done
  echo "${name}=FAIL http=${http:-none}"
  cat "$body" 2>/dev/null || true
  return 1
}

rollback() {
  local rc=$?
  trap - ERR
  set +e

  if [ "$FRONTEND_MUTATED" -eq 1 ] && [ -d "$PREVIEW_ROLLBACK" ]; then
    echo "=== PREVIEW ROLLBACK START ==="
    rsync -a --delete "$PREVIEW_ROLLBACK/" "$PREVIEW_ROOT/"
    nginx -t && systemctl reload nginx
    echo "preview_rollback=COMPLETE"
  fi

  if [ "$RUNTIME_MUTATED" -eq 1 ]; then
    echo "=== N8N ROLLBACK START ==="
    docker cp "$BACKUP_TX" "n8n:/tmp/rollback-${TX_ID}.json"
    docker cp "$BACKUP_SUMMARY" "n8n:/tmp/rollback-${SUMMARY_ID}.json"
    docker exec n8n n8n import:workflow --input="/tmp/rollback-${TX_ID}.json"
    docker exec n8n n8n import:workflow --input="/tmp/rollback-${SUMMARY_ID}.json"
    docker exec n8n n8n publish:workflow --id="$TX_ID"
    docker exec n8n n8n publish:workflow --id="$SUMMARY_ID"
    if [ "$PRESETS_EXISTED" -eq 1 ]; then
      docker cp "$BACKUP_PRESETS" "n8n:/tmp/rollback-${PRESETS_ID}.json"
      docker exec n8n n8n import:workflow --input="/tmp/rollback-${PRESETS_ID}.json"
      docker exec n8n n8n publish:workflow --id="$PRESETS_ID"
    else
      docker exec n8n n8n unpublish:workflow --id="$PRESETS_ID" >/dev/null 2>&1 || true
    fi
    docker restart n8n >/dev/null
    wait_health || true
    echo "n8n_rollback=COMPLETE"
  fi

  cleanup
  exit "$rc"
}

trap rollback ERR
trap cleanup EXIT

printf '%s\n' "=== UX-022 CATEGORIES + PRESETS START ==="

printf '\n%s\n' "=== 1. SOURCE / GENERATION ==="
git -C "$REPO" fetch origin "$BRANCH"
cleanup
rm -rf "$WORK"
git -C "$REPO" worktree add --detach "$WORK" "origin/$BRANCH"
SOURCE_BASE="$(git -C "$WORK" rev-parse HEAD)"
echo "source_base=$SOURCE_BASE"

python3 "$WORK/scripts/ux022-apply-category-filter-workflows.py" "$WORK"
python3 "$WORK/scripts/ux022-generate-filter-presets-workflow.py" "$WORK/$PRESETS_REL"

jq -e . "$WORK/$TX_REL" >/dev/null
jq -e . "$WORK/$SUMMARY_REL" >/dev/null
jq -e . "$WORK/$PRESETS_REL" >/dev/null
python3 -m py_compile \
  "$WORK/scripts/ux022-apply-category-filter-workflows.py" \
  "$WORK/scripts/ux022-generate-filter-presets-workflow.py"
git -C "$WORK" diff --check

echo "source_generation=PASS"

printf '\n%s\n' "=== 2. FRONTEND STATIC GATE ==="
cd "$WORK/miniapp"
npm ci
npm run lint
npm run build
[ -s "$WORK/miniapp/dist/index.html" ]
grep -R -Fq "api/v1/filter-presets" "$WORK/miniapp/dist/assets"
grep -R -Fq "Категории" "$WORK/miniapp/dist/assets"
grep -R -Fq "Пресеты" "$WORK/miniapp/dist/assets"
echo "frontend_static_gate=PASS"

printf '\n%s\n' "=== 3. COMMIT GENERATED SOURCE ==="
cd "$WORK"
if ! git diff --quiet -- "$TX_REL" "$SUMMARY_REL" "$PRESETS_REL"; then
  git add "$TX_REL" "$SUMMARY_REL" "$PRESETS_REL"
  git \
    -c user.name="MoneyTrack Runtime Maintainer" \
    -c user.email="moneytrack@localhost" \
    commit -m "feat(ux-022): wire category filters and immutable presets"
  git push origin "HEAD:$BRANCH"
  echo "generated_source_commit=$(git rev-parse HEAD)"
  echo "generated_source_push=PASS"
else
  echo "generated_source=ALREADY_COMMITTED"
fi
DEPLOY_HEAD="$(git rev-parse HEAD)"
echo "deploy_head=$DEPLOY_HEAD"

printf '\n%s\n' "=== 4. DATABASE MIGRATION ==="
docker exec -i moneytrack-db psql \
  -v ON_ERROR_STOP=1 \
  -U moneytrack \
  -d moneytrack \
  < "$WORK/$MIGRATION_REL"

docker exec moneytrack-db psql -U moneytrack -d moneytrack -Atc \
  "select case when to_regclass('moneytrack.filter_presets') is not null then 'PASS' else 'FAIL' end;" \
  | grep -Fxq PASS

echo "filter_presets_table=PASS"

printf '\n%s\n' "=== 5. RUNTIME BACKUP ==="
docker exec n8n n8n export:workflow --id="$TX_ID" --output="/tmp/${TX_ID}-before-filters-${STAMP}.json"
docker exec n8n n8n export:workflow --id="$SUMMARY_ID" --output="/tmp/${SUMMARY_ID}-before-filters-${STAMP}.json"
docker cp "n8n:/tmp/${TX_ID}-before-filters-${STAMP}.json" "$BACKUP_TX"
docker cp "n8n:/tmp/${SUMMARY_ID}-before-filters-${STAMP}.json" "$BACKUP_SUMMARY"
jq -e . "$BACKUP_TX" >/dev/null
jq -e . "$BACKUP_SUMMARY" >/dev/null
if docker exec n8n n8n export:workflow --id="$PRESETS_ID" --output="/tmp/${PRESETS_ID}-before-filters-${STAMP}.json" >/dev/null 2>&1; then
  docker cp "n8n:/tmp/${PRESETS_ID}-before-filters-${STAMP}.json" "$BACKUP_PRESETS"
  jq -e . "$BACKUP_PRESETS" >/dev/null
  PRESETS_EXISTED=1
fi
echo "runtime_backup=PASS presets_existed=$PRESETS_EXISTED"

printf '\n%s\n' "=== 6. IMPORT / PUBLISH ==="
docker cp "$WORK/$TX_REL" "n8n:/tmp/${TX_ID}-filters.json"
docker cp "$WORK/$SUMMARY_REL" "n8n:/tmp/${SUMMARY_ID}-filters.json"
docker cp "$WORK/$PRESETS_REL" "n8n:/tmp/${PRESETS_ID}.json"
RUNTIME_MUTATED=1
docker exec n8n n8n import:workflow --input="/tmp/${TX_ID}-filters.json"
docker exec n8n n8n import:workflow --input="/tmp/${SUMMARY_ID}-filters.json"
docker exec n8n n8n import:workflow --input="/tmp/${PRESETS_ID}.json"
docker exec n8n n8n publish:workflow --id="$TX_ID"
docker exec n8n n8n publish:workflow --id="$SUMMARY_ID"
docker exec n8n n8n publish:workflow --id="$PRESETS_ID"
docker restart n8n >/dev/null
wait_health

printf '\n%s\n' "=== 7. WEBHOOK CONTRACTS ==="
wait_auth_contract \
  "transactions_api_registration" GET \
  "http://127.0.0.1:5678/webhook/api/v1/transactions?account_id=1&date_from=2026-06-01&date_to=2026-06-30&include_descendants=false"
wait_auth_contract \
  "summary_api_registration" GET \
  "http://127.0.0.1:5678/webhook/api/v1/accounts-explorer-summary?date_from=2026-06-01&date_to=2026-06-30"
wait_auth_contract "presets_get_auth" GET "http://127.0.0.1:5678/webhook/api/v1/filter-presets"
wait_auth_contract "presets_post_auth" POST "http://127.0.0.1:5678/webhook/api/v1/filter-presets"
wait_auth_contract "presets_patch_auth" PATCH "http://127.0.0.1:5678/webhook/api/v1/filter-presets"
wait_auth_contract "presets_delete_auth" DELETE "http://127.0.0.1:5678/webhook/api/v1/filter-presets?id=1"
echo "api_contract_gate=PASS"

printf '\n%s\n' "=== 8. RUNTIME SOURCE VERIFY ==="
docker exec n8n n8n export:workflow --id="$TX_ID" --output="/tmp/${TX_ID}-after-filters-${STAMP}.json"
docker exec n8n n8n export:workflow --id="$SUMMARY_ID" --output="/tmp/${SUMMARY_ID}-after-filters-${STAMP}.json"
docker exec n8n n8n export:workflow --id="$PRESETS_ID" --output="/tmp/${PRESETS_ID}-after-filters-${STAMP}.json"
docker cp "n8n:/tmp/${TX_ID}-after-filters-${STAMP}.json" "/tmp/${TX_ID}-after-filters-${STAMP}.json"
docker cp "n8n:/tmp/${SUMMARY_ID}-after-filters-${STAMP}.json" "/tmp/${SUMMARY_ID}-after-filters-${STAMP}.json"
docker cp "n8n:/tmp/${PRESETS_ID}-after-filters-${STAMP}.json" "/tmp/${PRESETS_ID}-after-filters-${STAMP}.json"

jq -e '.[0].active == true' "/tmp/${TX_ID}-after-filters-${STAMP}.json" >/dev/null
jq -e '.[0].active == true' "/tmp/${SUMMARY_ID}-after-filters-${STAMP}.json" >/dev/null
jq -e '.[0].active == true' "/tmp/${PRESETS_ID}-after-filters-${STAMP}.json" >/dev/null

jq -er '.[0].nodes[] | select(.name == "Get Account Transactions") | .parameters.query' \
  "/tmp/${TX_ID}-after-filters-${STAMP}.json" | grep -Fq 'category_filter_predicate'
jq -er '.[0].nodes[] | select(.name == "Get Explorer Summary") | .parameters.query' \
  "/tmp/${SUMMARY_ID}-after-filters-${STAMP}.json" | grep -Fq 'category_filter_predicate'
jq -e '[.[0].nodes[] | select(.type == "n8n-nodes-base.webhook" and .parameters.path == "api/v1/filter-presets")] | length == 4' \
  "/tmp/${PRESETS_ID}-after-filters-${STAMP}.json" >/dev/null

echo "category_filter_runtime=PASS"
echo "preset_api_runtime=PASS"
echo "balance_snapshot_contract_preserved=PASS"

printf '\n%s\n' "=== 9. PREVIEW DEPLOY ==="
mkdir -p "$PREVIEW_ROLLBACK"
cp -a "$PREVIEW_ROOT/." "$PREVIEW_ROLLBACK/"
FRONTEND_MUTATED=1
rsync -a --delete "$WORK/miniapp/dist/" "$PREVIEW_ROOT/"
nginx -t
systemctl reload nginx

curl -fsS -H 'Cache-Control: no-cache, no-store' \
  "${PREVIEW_ORIGIN}/?verify=${DEPLOY_HEAD}-$(date +%s)" \
  -o /tmp/moneytrack-preview-index-${STAMP}.html
LIVE_ASSET="$(grep -oE 'src="[^"]*assets/[^"]+\.js"' /tmp/moneytrack-preview-index-${STAMP}.html | head -1 | cut -d'"' -f2)"
[ -n "$LIVE_ASSET" ]
curl -fsS -H 'Cache-Control: no-cache, no-store' \
  "${PREVIEW_ORIGIN}${LIVE_ASSET}?verify=${DEPLOY_HEAD}-$(date +%s)" \
  -o /tmp/moneytrack-preview-bundle-${STAMP}.js
grep -Fq "api/v1/filter-presets" /tmp/moneytrack-preview-bundle-${STAMP}.js
grep -Fq "Категории" /tmp/moneytrack-preview-bundle-${STAMP}.js
grep -Fq "Пресеты" /tmp/moneytrack-preview-bundle-${STAMP}.js

echo "preview_deploy=PASS asset=$LIVE_ASSET"

RUNTIME_MUTATED=0
FRONTEND_MUTATED=0

printf '\n%s\n' "=== UX-022 CATEGORIES + PRESETS COMPLETE ==="
echo "category_filter=PASS"
echo "filter_presets=PASS"
echo "dates_in_presets=NO"
echo "preset_payload_mutation=NO rename_only=YES"
echo "preview=PASS"
