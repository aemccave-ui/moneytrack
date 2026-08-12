#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/ux022-db-runtime.sh"
ux022_db_init

N8N_CONTAINER="${MONEYTRACK_N8N_CONTAINER:-n8n}"
API_BASE="${MONEYTRACK_API_BASE:-https://n8n.moneytrackapp.xyz/webhook}"
QUICK_ID="UX022QuickInput202608"
TEXT_ID="f5ioJKyPTupUMV9h"
PHOTO_ID="5VC0EcFB21rwTfoI"
CATEGORY_ID="UX022CategorySettings202608"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="${MONEYTRACK_BACKEND_6_8_BACKUP_DIR:-/var/backups/moneytrack/ux022r3-backend-6-8/$STAMP}"
WORK="$(mktemp -d /tmp/ux022r3-backend-6-8-apply.XXXXXX)"

DB_MUTATED=0
N8N_MUTATED=0
SUCCESS=0

for command_name in docker curl python3 grep; do
  command -v "$command_name" >/dev/null 2>&1 || { echo "runtime_preflight=FAIL missing_command=$command_name" >&2; exit 1; }
done
docker inspect "$N8N_CONTAINER" >/dev/null

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo 'clean_checkout=FAIL' >&2
  git status --short >&2
  exit 1
fi

export_one() {
  local id="$1" target="$2" remote="/tmp/ux022r3-b68-apply-$$-$id.json"
  docker exec -u 0 "$N8N_CONTAINER" rm -f "$remote" >/dev/null 2>&1 || true
  docker exec "$N8N_CONTAINER" n8n export:workflow --id="$id" --output="$remote" >/dev/null
  docker cp "$N8N_CONTAINER:$remote" "$target" >/dev/null
  docker exec -u 0 "$N8N_CONTAINER" rm -f "$remote" >/dev/null 2>&1 || true
  test -s "$target"
}

import_publish() {
  local file="$1" id="$2" remote="/tmp/$(basename "$file")"
  docker cp "$file" "$N8N_CONTAINER:$remote" >/dev/null
  docker exec "$N8N_CONTAINER" n8n import:workflow --input="$remote"
  docker exec "$N8N_CONTAINER" n8n publish:workflow --id="$id"
  docker exec -u 0 "$N8N_CONTAINER" rm -f "$remote" >/dev/null 2>&1 || true
}

import_inert_category() {
  local file="$WORK/category.rollback-inert.json"
  cat > "$file" <<JSON
{
  "id": "$CATEGORY_ID",
  "name": "MoneyTrack Category Settings API — rollback inert",
  "nodes": [],
  "connections": {},
  "settings": {"executionOrder": "v1"},
  "active": false
}
JSON
  docker cp "$file" "$N8N_CONTAINER:/tmp/ux022r3-category-rollback-inert.json" >/dev/null
  docker exec "$N8N_CONTAINER" n8n import:workflow --input=/tmp/ux022r3-category-rollback-inert.json >/dev/null || true
  docker exec -u 0 "$N8N_CONTAINER" rm -f /tmp/ux022r3-category-rollback-inert.json >/dev/null 2>&1 || true
}

rollback_runtime() {
  echo 'backend_6_8_rollback=START' >&2
  if (( N8N_MUTATED )); then
    import_publish "$BACKUP_DIR/quick.before.json" "$QUICK_ID" >/dev/null 2>&1 \
      && echo 'rollback_quick_workflow=PASS' >&2 || echo 'rollback_quick_workflow=FAIL' >&2
    import_publish "$BACKUP_DIR/text.before.json" "$TEXT_ID" >/dev/null 2>&1 \
      && echo 'rollback_text_workflow=PASS' >&2 || echo 'rollback_text_workflow=FAIL' >&2
    import_publish "$BACKUP_DIR/photo.before.json" "$PHOTO_ID" >/dev/null 2>&1 \
      && echo 'rollback_photo_workflow=PASS' >&2 || echo 'rollback_photo_workflow=FAIL' >&2
    import_inert_category
    docker restart "$N8N_CONTAINER" >/dev/null || echo 'rollback_n8n_restart=FAIL' >&2
  fi

  if (( DB_MUTATED )); then
    cat > "$WORK/db-rollback-prefix.sql" <<'SQL'
\set ON_ERROR_STOP on
begin;
drop function if exists moneytrack.category_update_v1(bigint,bigint,text,text);
drop function if exists moneytrack.receipt_finalize_transaction_metadata_v1(bigint,bigint,text,bigint);
drop function if exists moneytrack.catalog_ensure_user_categories_v1(bigint);
drop function if exists moneytrack.api_transaction_reference_read_model_v1(bigint);
alter table moneytrack.category_catalog drop constraint if exists category_catalog_flow_type_check;
alter table moneytrack.category_catalog drop column if exists flow_type;
commit;
SQL
    if ux022_db_psql_file "$WORK/db-rollback-prefix.sql" \
       && ux022_db_psql_file "$BACKUP_DIR/db-functions.before.sql" \
       && ux022_db_psql_file "$BACKUP_DIR/special-category-state.before.sql"; then
      echo 'rollback_db=PASS' >&2
    else
      echo 'rollback_db=FAIL use_schema_dump' >&2
    fi
  fi
  echo "rollback_point=$BACKUP_DIR" >&2
}

on_exit() {
  local status=$?
  trap - EXIT
  if (( ! SUCCESS )) && (( DB_MUTATED || N8N_MUTATED )); then
    echo "UX022R3_BACKEND_6_8_APPLY=FAIL status=$status" >&2
    rollback_runtime
  fi
  rm -rf "$WORK"
  exit "$status"
}
trap on_exit EXIT

echo '# Phase'
echo 'UX-022R3 backend 6-8 controlled runtime apply'
echo '# Gate'
echo 'CONTROLLED_MUTATION / ROLLBACK_REQUIRED'
echo "HEAD=$(git rev-parse HEAD)"
echo "db_runtime_mode=$UX022_DB_MODE"
echo 'clean_checkout=PASS'

# Mandatory read-only candidate gate immediately before mutation.
bash "$ROOT/scripts/ux022r3-backend-6-8-apply-gate.sh"
echo 'apply_preflight=PASS'

mkdir -p "$BACKUP_DIR"
printf '%s\n' "$(git rev-parse HEAD)" > "$BACKUP_DIR/source-head.txt"
ux022_db_pg_dump_schema moneytrack "$BACKUP_DIR/moneytrack.before.dump"
test -s "$BACKUP_DIR/moneytrack.before.dump"

export_one "$QUICK_ID" "$BACKUP_DIR/quick.before.json"
export_one "$TEXT_ID" "$BACKUP_DIR/text.before.json"
export_one "$PHOTO_ID" "$BACKUP_DIR/photo.before.json"

cat > "$WORK/function-backup.sql" <<'SQL'
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned
select pg_get_functiondef('moneytrack.catalog_ensure_user_categories_v1(bigint)'::regprocedure) || E';\n';
select pg_get_functiondef('moneytrack.api_transaction_reference_read_model_v1(bigint)'::regprocedure) || E';\n';
SQL
ux022_db_psql_file "$WORK/function-backup.sql" > "$BACKUP_DIR/db-functions.before.sql"
test -s "$BACKUP_DIR/db-functions.before.sql"

cat > "$WORK/special-backup.sql" <<'SQL'
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned
select 'begin;';
select format(
  'update moneytrack.category_catalog set is_active=%L where id=%s;',
  c.is_active,
  c.id
)
from moneytrack.category_catalog c
where c.code in ('transfer','uncategorized')
order by c.id;
select 'commit;';
SQL
ux022_db_psql_file "$WORK/special-backup.sql" > "$BACKUP_DIR/special-category-state.before.sql"
test -s "$BACKUP_DIR/special-category-state.before.sql"
echo "runtime_backup=PASS path=$BACKUP_DIR"

# Build candidates again from the exact backed-up active workflows.
python3 "$ROOT/scripts/ux022r3-patch-quick-ingress-time.py" "$BACKUP_DIR/quick.before.json" "$WORK/quick.candidate.json"
python3 "$ROOT/scripts/be-dom-001-transform-text-write.py" "$BACKUP_DIR/text.before.json" "$WORK/text.candidate.json"
python3 "$ROOT/scripts/ux022r3-patch-photo-receipt-clock.py" "$BACKUP_DIR/photo.before.json" "$WORK/photo.clock.json"
python3 "$ROOT/scripts/ux022r3-patch-receipt-operation-metadata.py" "$WORK/photo.clock.json" "$WORK/photo.candidate.json"
python3 "$ROOT/scripts/ux022r3-generate-category-settings-workflow.py" --output "$WORK/category.candidate.json"
echo 'apply_candidates_regenerated=PASS'

# Database source order is intentional: capability, bootstrap override, canonical
# semantic seed, then receipt transaction metadata finalizer.
DB_MUTATED=1
ux022_db_psql_file "$ROOT/db/domain/UX-022/070_category_flow_settings.sql"
ux022_db_psql_file "$ROOT/db/domain/UX-022/071_category_flow_bootstrap_hardening.sql"
ux022_db_psql_file "$ROOT/db/domain/UX-022/072_category_flow_canonical_seed.sql"
ux022_db_psql_file "$ROOT/db/domain/UX-022/080_receipt_operation_metadata.sql"
echo 'backend_db_apply=PASS'

N8N_MUTATED=1
import_publish "$WORK/quick.candidate.json" "$QUICK_ID"
import_publish "$WORK/text.candidate.json" "$TEXT_ID"
import_publish "$WORK/photo.candidate.json" "$PHOTO_ID"
import_publish "$WORK/category.candidate.json" "$CATEGORY_ID"
docker restart "$N8N_CONTAINER" >/dev/null
echo 'backend_n8n_publish_restart=PASS'

cat > "$WORK/db-verify.sql" <<'SQL'
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned
select 'flow_type_column=' || case when exists (
  select 1 from information_schema.columns
  where table_schema='moneytrack' and table_name='category_catalog' and column_name='flow_type'
) then 'PRESENT' else 'ABSENT' end;
select 'active_unresolved_categories=' || count(*)
from moneytrack.category_catalog c
where coalesce(c.is_active,true)=true and c.flow_type is null;
select 'active_special_categories=' || count(*)
from moneytrack.category_catalog c
where coalesce(c.is_active,true)=true and c.code in ('transfer','uncategorized');
select 'category_update_function=' || case when to_regprocedure('moneytrack.category_update_v1(bigint,bigint,text,text)') is not null then 'PRESENT' else 'ABSENT' end;
select 'receipt_finalizer_function=' || case when to_regprocedure('moneytrack.receipt_finalize_transaction_metadata_v1(bigint,bigint,text,bigint)') is not null then 'PRESENT' else 'ABSENT' end;
SQL
DB_VERIFY="$(ux022_db_psql_file "$WORK/db-verify.sql")"
printf '%s\n' "$DB_VERIFY"
grep -qx 'flow_type_column=PRESENT' <<<"$DB_VERIFY"
grep -qx 'active_unresolved_categories=0' <<<"$DB_VERIFY"
grep -qx 'active_special_categories=0' <<<"$DB_VERIFY"
grep -qx 'category_update_function=PRESENT' <<<"$DB_VERIFY"
grep -qx 'receipt_finalizer_function=PRESENT' <<<"$DB_VERIFY"
echo 'backend_db_verify=PASS'

# Export post-apply active/draft state and verify the intended contracts are now
# present. Metadata/version fields are intentionally ignored.
export_one "$QUICK_ID" "$WORK/quick.after.json"
export_one "$TEXT_ID" "$WORK/text.after.json"
export_one "$PHOTO_ID" "$WORK/photo.after.json"
export_one "$CATEGORY_ID" "$WORK/category.after.json"
python3 - "$WORK/quick.after.json" "$WORK/text.after.json" "$WORK/photo.after.json" "$WORK/category.after.json" <<'PY'
import json,sys
from pathlib import Path

def one(path):
    raw=json.loads(Path(path).read_text(encoding='utf-8'))
    return raw[0] if isinstance(raw,list) else raw
q,t,p,c=map(one,sys.argv[1:])
qb=json.dumps(q,ensure_ascii=False)
tb=json.dumps(t,ensure_ascii=False)
pb=json.dumps(p,ensure_ascii=False)
cb=json.dumps(c,ensure_ascii=False)
assert "Voice Prepare').first().json.message_date" in qb
assert 'message_date' in tb and 'to_timestamp' in tb
assert 'receipt_time' in pb and 'Never invent receipt_time' in pb
assert 'receipt_finalize_transaction_metadata_v1' in pb
assert str(c.get('id'))=='UX022CategorySettings202608' and 'api/v1/categories' in cb
print('backend_workflow_verify=PASS')
PY

# Wait for category PATCH webhook registration; missing auth must fail as 401.
ready=0
code=''
for _ in $(seq 1 45); do
  code="$(curl -sS -X PATCH -H 'Content-Type: application/json' -d '{}' -o "$WORK/category-readiness.json" -w '%{http_code}' "$API_BASE/api/v1/categories" || true)"
  if [[ "$code" == '401' ]]; then ready=1; break; fi
  sleep 2
done
if (( ! ready )); then
  echo "category_webhook_readiness=FAIL http=$code" >&2
  exit 1
fi
echo 'category_webhook_readiness=PASS http=401'

SUCCESS=1
DB_MUTATED=0
N8N_MUTATED=0

echo "rollback_point=$BACKUP_DIR"
echo 'DB_MUTATION=category_flow_and_receipt_metadata_APPLIED'
echo 'N8N_MUTATION=quick_text_photo_category_settings_PUBLISHED'
echo 'FRONTEND_MUTATION=NONE'
echo 'UX022R3_BACKEND_6_8_APPLY=PASS'
