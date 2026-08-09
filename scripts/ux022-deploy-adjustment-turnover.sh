#!/usr/bin/env bash
set -Eeuo pipefail

REPO="/home/adm_mt/moneytrack"
BRANCH="agent/ux-022-accounts-explorer"
WORK="/tmp/moneytrack-ux022-adjustment-turnover"
STAMP="$(date +%Y%m%dT%H%M%S)"

TX_ID="UX022TxApi202608"
SUMMARY_ID="UX022Summary202608"
TX_REL="workflows/moneytrack-transactions-api-UX022TxApi202608.json"
SUMMARY_REL="workflows/moneytrack-accounts-explorer-summary-UX022Summary202608.json"

BACKUP_TX="/tmp/${TX_ID}-before-adjustment-${STAMP}.json"
BACKUP_SUMMARY="/tmp/${SUMMARY_ID}-before-adjustment-${STAMP}.json"
MUTATED=0

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

wait_auth() {
  local name="$1"
  local url="$2"
  local body="/tmp/${name}-${STAMP}.json"
  local http=""
  local i
  for i in $(seq 1 90); do
    http="$(curl -sS --max-time 5 -o "$body" -w '%{http_code}' "$url" || true)"
    if [ "$http" = "401" ] && grep -Fq "INIT_DATA_MISSING" "$body"; then
      echo "${name}=PASS http=401 attempt=$i"
      return 0
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
  if [ "$MUTATED" -eq 1 ]; then
    echo "=== AUTOMATIC ROLLBACK START ==="
    docker cp "$BACKUP_TX" "n8n:/tmp/rollback-${TX_ID}.json"
    docker cp "$BACKUP_SUMMARY" "n8n:/tmp/rollback-${SUMMARY_ID}.json"
    docker exec n8n n8n import:workflow --input="/tmp/rollback-${TX_ID}.json"
    docker exec n8n n8n import:workflow --input="/tmp/rollback-${SUMMARY_ID}.json"
    docker exec n8n n8n publish:workflow --id="$TX_ID"
    docker exec n8n n8n publish:workflow --id="$SUMMARY_ID"
    docker restart n8n >/dev/null
    wait_health || true
    echo "automatic_rollback=COMPLETE"
  fi
  cleanup
  exit "$rc"
}

trap rollback ERR
trap cleanup EXIT

echo "=== UX-022 ADJUSTMENT TURNOVER FIX START ==="

echo
echo "=== 1. SOURCE ==="
git -C "$REPO" fetch origin "$BRANCH"
cleanup
rm -rf "$WORK"
git -C "$REPO" worktree add --detach "$WORK" "origin/$BRANCH"
echo "source_head=$(git -C "$WORK" rev-parse HEAD)"

echo
echo "=== 2. PATCH + STATIC VERIFY ==="
python3 "$WORK/scripts/ux022-fix-adjustment-turnover.py" "$WORK"
jq -e . "$WORK/$TX_REL" >/dev/null
jq -e . "$WORK/$SUMMARY_REL" >/dev/null
git -C "$WORK" diff --check
echo "source_validation=PASS"

if ! git -C "$WORK" diff --quiet -- "$TX_REL" "$SUMMARY_REL"; then
  git -C "$WORK" add "$TX_REL" "$SUMMARY_REL"
  git -C "$WORK" \
    -c user.name="MoneyTrack Runtime Maintainer" \
    -c user.email="moneytrack@localhost" \
    commit -m "fix(ux-022): classify adjustments as expense turnover"
  git -C "$WORK" push origin "HEAD:$BRANCH"
  echo "source_commit=$(git -C "$WORK" rev-parse HEAD)"
  echo "source_push=PASS"
else
  echo "source_patch=ALREADY_APPLIED"
fi

echo
echo "=== 3. RUNTIME BACKUP ==="
docker exec n8n n8n export:workflow --id="$TX_ID" --output="/tmp/${TX_ID}-before-adjustment-${STAMP}.json"
docker exec n8n n8n export:workflow --id="$SUMMARY_ID" --output="/tmp/${SUMMARY_ID}-before-adjustment-${STAMP}.json"
docker cp "n8n:/tmp/${TX_ID}-before-adjustment-${STAMP}.json" "$BACKUP_TX"
docker cp "n8n:/tmp/${SUMMARY_ID}-before-adjustment-${STAMP}.json" "$BACKUP_SUMMARY"
jq -e . "$BACKUP_TX" >/dev/null
jq -e . "$BACKUP_SUMMARY" >/dev/null
echo "runtime_backup=PASS"

echo
echo "=== 4. IMPORT / PUBLISH ==="
docker cp "$WORK/$TX_REL" "n8n:/tmp/${TX_ID}-adjustment-fix.json"
docker cp "$WORK/$SUMMARY_REL" "n8n:/tmp/${SUMMARY_ID}-adjustment-fix.json"
MUTATED=1
docker exec n8n n8n import:workflow --input="/tmp/${TX_ID}-adjustment-fix.json"
docker exec n8n n8n import:workflow --input="/tmp/${SUMMARY_ID}-adjustment-fix.json"
docker exec n8n n8n publish:workflow --id="$TX_ID"
docker exec n8n n8n publish:workflow --id="$SUMMARY_ID"
docker restart n8n >/dev/null
wait_health

echo
echo "=== 5. WEBHOOK REGISTRATION ==="
wait_auth \
  "transactions_api_registration" \
  "http://127.0.0.1:5678/webhook/api/v1/transactions?account_id=1&date_from=2026-06-01&date_to=2026-06-30&include_descendants=false"
wait_auth \
  "summary_api_registration" \
  "http://127.0.0.1:5678/webhook/api/v1/accounts-explorer-summary?date_from=2026-06-01&date_to=2026-06-30"

echo
echo "=== 6. RUNTIME SOURCE VERIFY ==="
docker exec n8n n8n export:workflow --id="$TX_ID" --output="/tmp/${TX_ID}-after-adjustment-${STAMP}.json"
docker exec n8n n8n export:workflow --id="$SUMMARY_ID" --output="/tmp/${SUMMARY_ID}-after-adjustment-${STAMP}.json"
docker cp "n8n:/tmp/${TX_ID}-after-adjustment-${STAMP}.json" "/tmp/${TX_ID}-after-adjustment-${STAMP}.json"
docker cp "n8n:/tmp/${SUMMARY_ID}-after-adjustment-${STAMP}.json" "/tmp/${SUMMARY_ID}-after-adjustment-${STAMP}.json"

jq -er '.[0].nodes[] | select(.name == "Get Account Transactions") | .parameters.query' \
  "/tmp/${TX_ID}-after-adjustment-${STAMP}.json" > "/tmp/${TX_ID}-query-${STAMP}.sql"
jq -er '.[0].nodes[] | select(.name == "Get Explorer Summary") | .parameters.query' \
  "/tmp/${SUMMARY_ID}-after-adjustment-${STAMP}.json" > "/tmp/${SUMMARY_ID}-query-${STAMP}.sql"

grep -Fq "transaction_type in ('expense', 'adjustment')" "/tmp/${TX_ID}-query-${STAMP}.sql"
grep -Fq "transaction_type in ('expense', 'adjustment')" "/tmp/${SUMMARY_ID}-query-${STAMP}.sql"
grep -Fq "(ps.income - ps.expense) as period_result" "/tmp/${SUMMARY_ID}-query-${STAMP}.sql"
grep -Fq "snapshot_summary as" "/tmp/${SUMMARY_ID}-query-${STAMP}.sql"

echo "adjustment_turnover_contract=PASS"
echo "balance_snapshot_contract_preserved=PASS"

MUTATED=0

echo
echo "=== UX-022 ADJUSTMENT TURNOVER FIX COMPLETE ==="
echo "expected_adjustment_50=saldo_-50_income_0_expense_50"
echo "frontend_redeploy_required=NO"
