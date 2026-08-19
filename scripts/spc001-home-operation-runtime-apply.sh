#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APPLY=0
EXPECTED_HEAD=""
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="${MONEYTRACK_HOME_OPEN_BACKUP_DIR:-/var/backups/moneytrack/spc001-home-operation-open/$STAMP}"
WORK="$(mktemp -d /tmp/spc001-home-operation-open.XXXXXX)"
DB_MUTATED=0
SUCCESS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --expected-head) EXPECTED_HEAD="${2:-}"; shift 2 ;;
    --backup-dir) BACKUP_DIR="${2:-}"; shift 2 ;;
    *) echo "ERROR: unexpected argument: $1" >&2; exit 2 ;;
  esac
done

[[ "$APPLY" -eq 1 ]] || { echo 'SPC001_HOME_OPERATION_RUNTIME_APPLY=REFUSED explicit_--apply_required' >&2; exit 2; }
[[ -n "$EXPECTED_HEAD" ]] || { echo 'SPC001_HOME_OPERATION_RUNTIME_APPLY=REFUSED expected_head_required' >&2; exit 2; }
[[ "$BACKUP_DIR" = /* ]] || { echo 'ERROR: absolute backup path required' >&2; exit 2; }
case "$BACKUP_DIR" in /tmp|/tmp/*) echo 'ERROR: durable backup path required' >&2; exit 2;; esac

HEAD_SHA="$(git rev-parse HEAD)"
[[ "$HEAD_SHA" == "$EXPECTED_HEAD" ]] || { echo "ERROR: head mismatch expected=$EXPECTED_HEAD actual=$HEAD_SHA" >&2; exit 1; }
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || { echo 'ERROR: dirty checkout' >&2; git status --short >&2; exit 1; }

git merge-base --is-ancestor 9eb3548c59c675ada5a1da662914a7418d83cb9a "$HEAD_SHA" || {
  echo 'ERROR: required Home operation contract merge is not an ancestor' >&2
  exit 1
}

source "$ROOT/scripts/ux022-db-runtime.sh"
ux022_db_init

cleanup() { rm -rf "$WORK"; }

restore_functions() {
  local restore="$WORK/restore-functions.sql"
  {
    echo 'begin;'
    cat "$BACKUP_DIR/finance-dashboard-space-v1.before.sql"
    cat "$BACKUP_DIR/receipt-projection-api-read-v1.before.sql"
    echo 'commit;'
  } > "$restore"
  ux022_db_psql_file "$restore" >/dev/null
}

rollback() {
  local rc="${1:-1}"
  trap - ERR EXIT
  echo "ROLLBACK_TRIGGERED=YES rc=$rc" >&2
  if (( DB_MUTATED )); then
    if restore_functions; then
      echo 'DB_FUNCTION_ROLLBACK=PASS' >&2
    else
      echo 'DB_FUNCTION_ROLLBACK=FAIL' >&2
    fi
  fi
  echo "rollback_point=$BACKUP_DIR" >&2
  echo "SPC001_HOME_OPERATION_RUNTIME_APPLY=FAIL rc=$rc" >&2
  cleanup
  exit "$rc"
}

on_exit() {
  local rc=$?
  if (( rc != 0 && SUCCESS == 0 && DB_MUTATED )); then
    rollback "$rc"
  fi
  cleanup
}
trap 'rollback $?' ERR
trap on_exit EXIT

for cmd in git python3; do command -v "$cmd" >/dev/null; done
[[ -s "$ROOT/db/domain/SPC-001/219_home_operation_open_contract_repair.sql" ]]
python3 "$ROOT/scripts/spc001-home-operation-contract-gate.py"

echo '# Phase'
echo 'SPC-001 Home operation open runtime repair'
echo '# Gate'
echo 'CONTROLLED_DB_FUNCTION_MUTATION_ONLY'
echo "HEAD=$HEAD_SHA"
echo "db_runtime_mode=$UX022_DB_MODE"
echo 'N8N_MUTATION=NONE'
echo 'FRONTEND_MUTATION=NONE'

mkdir -p "$BACKUP_DIR"
printf '%s\n' "$HEAD_SHA" > "$BACKUP_DIR/source-head.txt"
ux022_db_pg_dump_schema moneytrack "$BACKUP_DIR/moneytrack-schema-before.dump"

cat > "$WORK/capture-dashboard.sql" <<'SQL'
\set QUIET 1
\pset tuples_only on
\pset format unaligned
select pg_get_functiondef('moneytrack.finance_dashboard_space_read_model_v1(bigint,bigint,date)'::regprocedure) || E';';
SQL
ux022_db_psql_file "$WORK/capture-dashboard.sql" > "$BACKUP_DIR/finance-dashboard-space-v1.before.sql"

cat > "$WORK/capture-receipt.sql" <<'SQL'
\set QUIET 1
\pset tuples_only on
\pset format unaligned
select pg_get_functiondef('moneytrack.receipt_projection_api_read_v1(bigint,bigint,bigint)'::regprocedure) || E';';
SQL
ux022_db_psql_file "$WORK/capture-receipt.sql" > "$BACKUP_DIR/receipt-projection-api-read-v1.before.sql"

grep -qi 'create or replace function moneytrack.finance_dashboard_space_read_model_v1' "$BACKUP_DIR/finance-dashboard-space-v1.before.sql"
grep -qi 'create or replace function moneytrack.receipt_projection_api_read_v1' "$BACKUP_DIR/receipt-projection-api-read-v1.before.sql"
echo "runtime_backup=PASS path=$BACKUP_DIR"

ux022_db_psql_file "$ROOT/db/domain/SPC-001/219_home_operation_open_contract_repair.sql" >/dev/null
DB_MUTATED=1
echo 'db_contract_apply=PASS'

cat > "$WORK/verify.sql" <<'SQL'
\set QUIET 1
\pset tuples_only on
\pset format unaligned

select 'dashboard_source_kind_definition=' || case
  when position('source_kind' in pg_get_functiondef('moneytrack.finance_dashboard_space_read_model_v1(bigint,bigint,date)'::regprocedure)) > 0
   and position('capture_events' in pg_get_functiondef('moneytrack.finance_dashboard_space_read_model_v1(bigint,bigint,date)'::regprocedure)) > 0
  then 'PASS' else 'FAIL' end;

select 'receipt_nullable_definition=' || case
  when position('TRANSACTION_NOT_FOUND_IN_SPACE' in pg_get_functiondef('moneytrack.receipt_projection_api_read_v1(bigint,bigint,bigint)'::regprocedure)) > 0
   and position('RECEIPT_PROJECTION_NOT_FOUND_IN_SPACE' in pg_get_functiondef('moneytrack.receipt_projection_api_read_v1(bigint,bigint,bigint)'::regprocedure)) = 0
  then 'PASS' else 'FAIL' end;

with candidate as (
  select wm.user_id actor_user_id, t.space_id, t.id transaction_id
  from moneytrack.transactions t
  join moneytrack.workspace_members wm
    on wm.workspace_id=t.space_id and coalesce(wm.is_active,true)=true
  where t.space_id is not null
    and lower(coalesce(t.source_type,'manual')) not in ('photo','photo_receipt')
    and not exists (select 1 from moneytrack.receipts r where r.transaction_id=t.id)
    and not exists (
      select 1 from moneytrack.capture_receipts cr
      where cr.capture_event_id=t.capture_event_id
    )
  order by t.id desc
  limit 1
)
select 'ordinary_receipt_lookup=' || case
  when not exists(select 1 from candidate) then 'SKIP_NO_CANDIDATE'
  when (select moneytrack.receipt_projection_api_read_v1(actor_user_id,space_id,transaction_id) is null from candidate)
    then 'PASS' else 'FAIL' end;

with candidate as (
  select wm.user_id actor_user_id, t.space_id, t.id transaction_id
  from moneytrack.transactions t
  join moneytrack.workspace_members wm
    on wm.workspace_id=t.space_id and coalesce(wm.is_active,true)=true
  join moneytrack.capture_receipts cr on cr.capture_event_id=t.capture_event_id
  where t.space_id is not null
  order by t.id desc
  limit 1
)
select 'receipt_projection_lookup=' || case
  when not exists(select 1 from candidate) then 'SKIP_NO_CANDIDATE'
  when (select moneytrack.receipt_projection_api_read_v1(actor_user_id,space_id,transaction_id) is not null from candidate)
    then 'PASS' else 'FAIL' end;

with candidate as (
  select wm.user_id actor_user_id, t.space_id
  from moneytrack.transactions t
  join moneytrack.workspace_members wm
    on wm.workspace_id=t.space_id and coalesce(wm.is_active,true)=true
  where t.space_id is not null
  order by t.id desc
  limit 1
), payload as (
  select d.latest_operations
  from candidate c
  cross join lateral moneytrack.finance_dashboard_space_read_model_v1(c.actor_user_id,c.space_id,current_date) d
), rows as (
  select jsonb_array_elements(latest_operations) item from payload
)
select 'home_latest_source_kind_key=' || case
  when not exists(select 1 from candidate) then 'SKIP_NO_CANDIDATE'
  when not exists(select 1 from rows where not (item ? 'source_kind')) then 'PASS'
  else 'FAIL' end;

do $verify$
declare v_actor bigint; v_space bigint; v_failed_closed boolean:=false;
begin
  select wm.user_id,t.space_id into v_actor,v_space
  from moneytrack.transactions t
  join moneytrack.workspace_members wm on wm.workspace_id=t.space_id and coalesce(wm.is_active,true)=true
  where t.space_id is not null order by t.id desc limit 1;
  if v_actor is null then
    raise notice 'unknown_transaction_fail_closed=SKIP_NO_CANDIDATE';
    return;
  end if;
  begin
    perform moneytrack.receipt_projection_api_read_v1(v_actor,v_space,9223372036854775807::bigint);
  exception when sqlstate 'P0002' then
    if position('TRANSACTION_NOT_FOUND_IN_SPACE' in sqlerrm)>0 then v_failed_closed:=true; end if;
  end;
  if not v_failed_closed then raise exception 'UNKNOWN_TRANSACTION_FAIL_CLOSED_VERIFY_FAILED'; end if;
  raise notice 'unknown_transaction_fail_closed=PASS';
end;$verify$;
SQL

VERIFY="$(ux022_db_psql_file "$WORK/verify.sql" 2>&1)"
printf '%s\n' "$VERIFY"
grep -q '^dashboard_source_kind_definition=PASS$' <<<"$VERIFY"
grep -q '^receipt_nullable_definition=PASS$' <<<"$VERIFY"
! grep -q '=FAIL$' <<<"$VERIFY"
grep -Eq '^ordinary_receipt_lookup=(PASS|SKIP_NO_CANDIDATE)$' <<<"$VERIFY"
grep -Eq '^receipt_projection_lookup=(PASS|SKIP_NO_CANDIDATE)$' <<<"$VERIFY"
grep -Eq '^home_latest_source_kind_key=(PASS|SKIP_NO_CANDIDATE)$' <<<"$VERIFY"
grep -Eq 'unknown_transaction_fail_closed=PASS|unknown_transaction_fail_closed=SKIP_NO_CANDIDATE' <<<"$VERIFY"

echo 'runtime_verify=PASS'
{
  echo "HEAD=$HEAD_SHA"
  echo "DB_RUNTIME_MODE=$UX022_DB_MODE"
  echo 'DB_MUTATION=FUNCTIONS_APPLIED'
  echo 'N8N_MUTATION=NONE'
  echo 'FRONTEND_MUTATION=NONE'
  echo 'RUNTIME_VERIFY=PASS'
  echo 'SPC001_HOME_OPERATION_RUNTIME_APPLY=PASS'
} > "$BACKUP_DIR/metadata.txt"

(
  cd "$BACKUP_DIR"
  sha256sum source-head.txt moneytrack-schema-before.dump \
    finance-dashboard-space-v1.before.sql receipt-projection-api-read-v1.before.sql metadata.txt \
    > SHA256SUMS
)

SUCCESS=1
trap - ERR EXIT
cleanup
echo "evidence_dir=$BACKUP_DIR"
echo 'SPC001_HOME_OPERATION_RUNTIME_APPLY=PASS'
