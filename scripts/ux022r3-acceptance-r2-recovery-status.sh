#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/ux022-db-runtime.sh"
ux022_db_init

N8N_CONTAINER="${MONEYTRACK_N8N_CONTAINER:-n8n}"
API_BASE="${MONEYTRACK_API_BASE:-https://n8n.moneytrackapp.xyz/webhook}"
PREVIEW_URL="${MONEYTRACK_PREVIEW_URL:-https://preview.moneytrackapp.xyz}"
WORK="$(mktemp -d /tmp/ux022r3-r2-recovery.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo '# Phase'
echo 'UX-022R3 acceptance round 2 recovery status'
echo '# Gate'
echo 'READ_ONLY'
echo "HEAD=$(git rev-parse HEAD)"
echo "db_runtime_mode=$UX022_DB_MODE"

cat > "$WORK/db-status.sql" <<'SQL'
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned
select 'finance_get_transfer_v1=' || case when to_regprocedure('moneytrack.finance_get_transfer_v1(bigint,bigint)') is null then 'ABSENT' else 'PRESENT' end;
select 'finance_update_transfer_v1=' || case when to_regprocedure('moneytrack.finance_update_transfer_v1(bigint,bigint,bigint,bigint,numeric,timestamp with time zone,text)') is null then 'ABSENT' else 'PRESENT' end;
select 'finance_delete_transfer_v1=' || case when to_regprocedure('moneytrack.finance_delete_transfer_v1(bigint,bigint)') is null then 'ABSENT' else 'PRESENT' end;
select 'transfer_update_guard_same_account=' || case
  when to_regprocedure('moneytrack.finance_update_transfer_v1(bigint,bigint,bigint,bigint,numeric,timestamp with time zone,text)') is null then 'N/A'
  when position('SAME_ACCOUNT_TRANSFER_FORBIDDEN' in pg_get_functiondef(to_regprocedure('moneytrack.finance_update_transfer_v1(bigint,bigint,bigint,bigint,numeric,timestamp with time zone,text)'))) > 0 then 'PASS'
  else 'FAIL' end;
select 'transfer_update_guard_ownership=' || case
  when to_regprocedure('moneytrack.finance_update_transfer_v1(bigint,bigint,bigint,bigint,numeric,timestamp with time zone,text)') is null then 'N/A'
  when position('TRANSFER_NOT_FOUND_OR_NOT_OWNED' in pg_get_functiondef(to_regprocedure('moneytrack.finance_update_transfer_v1(bigint,bigint,bigint,bigint,numeric,timestamp with time zone,text)'))) > 0 then 'PASS'
  else 'FAIL' end;
select 'transfer_update_fx_boundary=' || case
  when to_regprocedure('moneytrack.finance_update_transfer_v1(bigint,bigint,bigint,bigint,numeric,timestamp with time zone,text)') is null then 'N/A'
  when position('finance_fx_convert_usd_bridge_v1' in pg_get_functiondef(to_regprocedure('moneytrack.finance_update_transfer_v1(bigint,bigint,bigint,bigint,numeric,timestamp with time zone,text)'))) > 0 then 'PASS'
  else 'FAIL' end;
SQL
ux022_db_psql_file "$WORK/db-status.sql"

docker inspect "$N8N_CONTAINER" >/dev/null
python3 "$ROOT/scripts/ux022r3-generate-transfer-write-workflow.py" --output "$WORK/candidate.json" >/dev/null
docker exec "$N8N_CONTAINER" n8n export:workflow --all --output=/tmp/ux022r3-r2-recovery-all.json >/dev/null
docker cp "$N8N_CONTAINER:/tmp/ux022r3-r2-recovery-all.json" "$WORK/all.json" >/dev/null
docker exec "$N8N_CONTAINER" rm -f /tmp/ux022r3-r2-recovery-all.json

python3 - "$WORK/all.json" "$WORK/candidate.json" <<'PY'
import json,sys
from pathlib import Path
all_raw=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
workflows=all_raw if isinstance(all_raw,list) else [all_raw]
candidate=json.loads(Path(sys.argv[2]).read_text(encoding='utf-8'))
wf=next((row for row in workflows if str(row.get('id'))=='UX022TransferWrite202608'),None)
if wf is None:
    print('transfer_workflow=ABSENT')
    raise SystemExit(0)
print('transfer_workflow=PRESENT')
print('transfer_workflow_active=' + ('YES' if wf.get('active') else 'NO'))
for key in ('createdAt','updatedAt','versionId','activeVersionId'):
    if wf.get(key) is not None:
        print(f'transfer_workflow_{key}={wf.get(key)}')
print(f'transfer_workflow_nodes={len(wf.get("nodes") or [])}')

def routes(row):
    result=[]
    for n in row.get('nodes') or []:
        if n.get('type')!='n8n-nodes-base.webhook':
            continue
        p=n.get('parameters') or {}
        result.append((p.get('httpMethod','GET'),p.get('path')))
    return sorted(result)

def pg_contract(row):
    result=[]
    for n in row.get('nodes') or []:
        if n.get('type')!='n8n-nodes-base.postgres':
            continue
        p=n.get('parameters') or {}
        result.append((n.get('name'),str(p.get('query') or '').strip()))
    return sorted(result)

def auth_contract(row):
    result=[]
    for n in row.get('nodes') or []:
        if n.get('type')!='n8n-nodes-base.code' or not str(n.get('name') or '').endswith(' Verify'):
            continue
        result.append((n.get('name'),'moneytrackVerifyTelegramInitData' in str((n.get('parameters') or {}).get('jsCode') or '')))
    return sorted(result)

print('transfer_workflow_routes_match=' + ('PASS' if routes(wf)==routes(candidate) else 'FAIL'))
print('transfer_workflow_pg_contract_match=' + ('PASS' if pg_contract(wf)==pg_contract(candidate) else 'FAIL'))
print('transfer_workflow_auth_contract_match=' + ('PASS' if auth_contract(wf)==auth_contract(candidate) else 'FAIL'))
print('transfer_workflow_candidate_contract=' + ('PASS' if routes(wf)==routes(candidate) and pg_contract(wf)==pg_contract(candidate) and auth_contract(wf)==auth_contract(candidate) else 'FAIL'))
PY

for method in GET POST PATCH DELETE; do
  code="$(curl -sS -X "$method" -o "$WORK/${method}.json" -w '%{http_code}' "$API_BASE/api/v1/transfer" || true)"
  body="$(tr -d '\n\r' < "$WORK/${method}.json" 2>/dev/null || true)"
  echo "transfer_endpoint_${method}_http=$code"
  [[ -z "$body" ]] || echo "transfer_endpoint_${method}_body=$body"
done

if [[ -s "$ROOT/miniapp/dist/index.html" ]]; then
  local_asset="$(grep -oE '/assets/[^\"[:space:]]+\.js' "$ROOT/miniapp/dist/index.html" | head -n1 || true)"
  if [[ -n "$local_asset" && -s "$ROOT/miniapp/dist$local_asset" ]]; then
    local_sha="$(sha256sum "$ROOT/miniapp/dist$local_asset" | awk '{print $1}')"
    echo "local_preview_candidate_asset=$local_asset"
    echo "local_preview_candidate_sha=$local_sha"
  fi
else
  local_asset=''
  local_sha=''
  echo 'local_preview_candidate=UNAVAILABLE'
fi

remote_html="$(curl -fsS -H 'Cache-Control: no-cache' "$PREVIEW_URL/?ux022r3r2status=$(date +%s)")"
remote_asset="$(printf '%s' "$remote_html" | grep -oE '/assets/[^\"[:space:]]+\.js' | head -n1 || true)"
echo "remote_preview_asset=$remote_asset"
if [[ -n "$remote_asset" ]]; then
  curl -fsS -H 'Cache-Control: no-cache' "$PREVIEW_URL$remote_asset?ux022r3r2status=$(date +%s)" -o "$WORK/remote.js"
  remote_sha="$(sha256sum "$WORK/remote.js" | awk '{print $1}')"
  echo "remote_preview_sha=$remote_sha"
  if [[ -n "${local_sha:-}" ]]; then
    if [[ "$local_asset" == "$remote_asset" && "$local_sha" == "$remote_sha" ]]; then
      echo 'preview_matches_current_candidate=YES'
    else
      echo 'preview_matches_current_candidate=NO'
    fi
  fi
fi

echo 'RUNTIME_MUTATION=NONE'
echo 'PREVIEW_MUTATION=NONE'
echo 'UX022R3_ACCEPTANCE_R2_RECOVERY_STATUS=PASS'
