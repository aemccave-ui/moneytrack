#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/be-dom-001-cutover-workflow.sh INPUT.json OUTPUT.json

Purpose:
  Produce a candidate MoneyTrack MiniApp API workflow in which only the
  finance SQL of "Get Dashboard" and "Get Accounts" is replaced by calls to
  BE-DOM-001 PostgreSQL read-model entry points.

The input file is never modified in place.
EOF
}

[[ $# -eq 2 ]] || {
  usage >&2
  exit 2
}

INPUT=$1
OUTPUT=$2

command -v jq >/dev/null 2>&1 || {
  echo "jq is required" >&2
  exit 127
}

[[ -f "$INPUT" ]] || {
  echo "Input workflow does not exist: $INPUT" >&2
  exit 2
}

[[ "$INPUT" != "$OUTPUT" ]] || {
  echo "Refusing in-place workflow mutation. Use a distinct OUTPUT path." >&2
  exit 3
}

DASHBOARD_SQL=$(cat <<'SQL'
with caller as (
    select u.id::bigint as user_id
    from moneytrack.app_users u
    where u.telegram_user_id = {{ $json.telegram_user_id }}::bigint
    limit 1
)
select rm.*
from caller c
cross join lateral moneytrack.finance_dashboard_read_model_v1(
    c.user_id,
    current_date
) rm;
SQL
)

ACCOUNTS_SQL=$(cat <<'SQL'
with caller as (
    select u.id::bigint as user_id
    from moneytrack.app_users u
    where u.telegram_user_id = {{ $json.telegram_user_id }}::bigint
    limit 1
)
select rm.*
from caller c
cross join lateral moneytrack.finance_accounts_read_model_v1(
    c.user_id
) rm;
SQL
)

DASHBOARD_COUNT=$(jq '[.nodes[] | select(.name == "Get Dashboard")] | length' "$INPUT")
ACCOUNTS_COUNT=$(jq '[.nodes[] | select(.name == "Get Accounts")] | length' "$INPUT")
DASHBOARD_FORMATTER_COUNT=$(jq '[.nodes[] | select(.name == "Format Dashboard Response")] | length' "$INPUT")

[[ "$DASHBOARD_COUNT" == "1" ]] || {
  echo "Expected exactly one 'Get Dashboard' node, found $DASHBOARD_COUNT" >&2
  exit 4
}
[[ "$ACCOUNTS_COUNT" == "1" ]] || {
  echo "Expected exactly one 'Get Accounts' node, found $ACCOUNTS_COUNT" >&2
  exit 4
}
[[ "$DASHBOARD_FORMATTER_COUNT" == "1" ]] || {
  echo "Expected exactly one 'Format Dashboard Response' node, found $DASHBOARD_FORMATTER_COUNT" >&2
  exit 4
}

jq \
  --arg dashboard_sql "$DASHBOARD_SQL" \
  --arg accounts_sql "$ACCOUNTS_SQL" \
  '
    .nodes |= map(
      if .name == "Get Dashboard" then
        .parameters.query = $dashboard_sql
      elif .name == "Get Accounts" then
        .parameters.query = $accounts_sql
      else
        .
      end
    )
  ' \
  "$INPUT" > "$OUTPUT.tmp"

jq empty "$OUTPUT.tmp"
mv "$OUTPUT.tmp" "$OUTPUT"

# Post-transform structural assertions.
jq -e --arg q "$DASHBOARD_SQL" '
  [.nodes[] | select(.name == "Get Dashboard" and .parameters.query == $q)] | length == 1
' "$OUTPUT" >/dev/null

jq -e --arg q "$ACCOUNTS_SQL" '
  [.nodes[] | select(.name == "Get Accounts" and .parameters.query == $q)] | length == 1
' "$OUTPUT" >/dev/null

# Ensure the legacy finance formulas are no longer embedded in these two nodes.
if jq -r '.nodes[] | select(.name == "Get Dashboard" or .name == "Get Accounts") | .parameters.query // ""' "$OUTPUT" \
  | grep -Eq 'exchange_rates_usd|sum\(t\.amount_original\)|sum\(t\.amount_base\)|month_summary|account_balances_report'; then
  echo "Legacy finance SQL marker still present after cutover transform" >&2
  rm -f "$OUTPUT"
  exit 5
fi

echo "Candidate workflow written to: $OUTPUT"
echo "No runtime/publish action was performed. Validate DB parity before import/publish."
