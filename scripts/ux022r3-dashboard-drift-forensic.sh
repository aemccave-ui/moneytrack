#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

N8N_CONTAINER="${MONEYTRACK_N8N_CONTAINER:-n8n}"
DASHBOARD_ID="7TJ2xQTxLsTydXZc"
WORK="$(mktemp -d /tmp/ux022r3-dashboard-drift.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

container_tmp_rm() {
  local remote="$1"
  docker exec -u 0 "$N8N_CONTAINER" rm -f "$remote" >/dev/null 2>&1 || true
}

export_one() {
  local id="$1"
  local target="$2"
  local remote="/tmp/ux022r3-dashboard-drift-$$-${id}.json"
  container_tmp_rm "$remote"
  docker exec "$N8N_CONTAINER" n8n export:workflow --id="$id" --output="$remote" >/dev/null
  docker cp "$N8N_CONTAINER:$remote" "$target" >/dev/null
  container_tmp_rm "$remote"
}

echo '# Phase'
echo 'UX-022R3 dashboard draft/active drift forensic'
echo '# Gate'
echo 'READ_ONLY'
echo "HEAD=$(git rev-parse HEAD)"

docker inspect "$N8N_CONTAINER" >/dev/null
export_one "$DASHBOARD_ID" "$WORK/dashboard.export.json"

python3 - "$WORK/dashboard.export.json" "$WORK/dashboard.meta" <<'PY'
import json,sys
from pathlib import Path
raw=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
wf=raw[0] if isinstance(raw,list) else raw
vid=str(wf.get('versionId') or '')
avid=str(wf.get('activeVersionId') or '')
Path(sys.argv[2]).write_text(f'{vid}\n{avid}\n',encoding='utf-8')
print(f'dashboard_active={"YES" if wf.get("active") is True else "NO"}')
print(f'dashboard_versionId={vid}')
print(f'dashboard_activeVersionId={avid}')
print(f'dashboard_published={"PASS" if vid and vid==avid else "DRIFT"}')
print(f'dashboard_export_nodes={len(wf.get("nodes") or [])}')
PY

mapfile -t META < "$WORK/dashboard.meta"
DRAFT_VERSION_ID="${META[0]:-}"
ACTIVE_VERSION_ID="${META[1]:-}"
[[ -n "$DRAFT_VERSION_ID" && -n "$ACTIVE_VERSION_ID" ]] || { echo 'dashboard_version_metadata=FAIL' >&2; exit 1; }

DB_TYPE="$(docker exec "$N8N_CONTAINER" sh -c 'printf "%s" "${DB_TYPE:-sqlite}"' 2>/dev/null || true)"
if [[ "$DB_TYPE" != 'postgresdb' && "$DB_TYPE" != 'postgres' ]]; then
  echo "n8n_db_type=${DB_TYPE:-unknown}"
  echo 'dashboard_drift_forensic=UNSUPPORTED_DB_TYPE'
  exit 1
fi

PG_HOST="$(docker exec "$N8N_CONTAINER" sh -c 'printf "%s" "${DB_POSTGRESDB_HOST:-}"' 2>/dev/null || true)"
PG_PORT="$(docker exec "$N8N_CONTAINER" sh -c 'printf "%s" "${DB_POSTGRESDB_PORT:-5432}"' 2>/dev/null || true)"
PG_DB="$(docker exec "$N8N_CONTAINER" sh -c 'printf "%s" "${DB_POSTGRESDB_DATABASE:-n8n}"' 2>/dev/null || true)"
PG_USER="$(docker exec "$N8N_CONTAINER" sh -c 'printf "%s" "${DB_POSTGRESDB_USER:-}"' 2>/dev/null || true)"
PG_SCHEMA="$(docker exec "$N8N_CONTAINER" sh -c 'printf "%s" "${DB_POSTGRESDB_SCHEMA:-public}"' 2>/dev/null || true)"
PG_PASS="$(docker exec "$N8N_CONTAINER" sh -c 'printf "%s" "${DB_POSTGRESDB_PASSWORD:-}"' 2>/dev/null || true)"

[[ -n "$PG_HOST" ]] || { echo 'n8n_postgres_host=EMPTY' >&2; exit 1; }
docker inspect "$PG_HOST" >/dev/null 2>&1 || { echo "n8n_postgres_container=UNAVAILABLE host=$PG_HOST" >&2; exit 1; }

psql_q() {
  local sql="$1"
  docker exec -e PGPASSWORD="$PG_PASS" "$PG_HOST" psql -X -qAt \
    -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -c "$sql"
}

printf 'n8n_version='
docker exec "$N8N_CONTAINER" n8n --version 2>/dev/null | tail -n 1

HISTORY_EXISTS="$(psql_q "select case when to_regclass(format('%I.workflow_history', '$PG_SCHEMA')) is null then 'NO' else 'YES' end;")"
ENTITY_EXISTS="$(psql_q "select case when to_regclass(format('%I.workflow_entity', '$PG_SCHEMA')) is null then 'NO' else 'YES' end;")"
echo "workflow_entity_table=$ENTITY_EXISTS"
echo "workflow_history_table=$HISTORY_EXISTS"
[[ "$ENTITY_EXISTS" == 'YES' ]] || exit 1

psql_q "select to_jsonb(w)::text from \"$PG_SCHEMA\".workflow_entity w where w.id='$DASHBOARD_ID';" > "$WORK/entity.jsonl"

if [[ "$HISTORY_EXISTS" == 'YES' ]]; then
  HISTORY_HAS_WORKFLOW="$(psql_q "select case when exists(select 1 from information_schema.columns where table_schema='$PG_SCHEMA' and table_name='workflow_history' and column_name='workflowId') then 'YES' else 'NO' end;")"
  HISTORY_HAS_VERSION="$(psql_q "select case when exists(select 1 from information_schema.columns where table_schema='$PG_SCHEMA' and table_name='workflow_history' and column_name='versionId') then 'YES' else 'NO' end;")"
  echo "workflow_history_workflowId_column=$HISTORY_HAS_WORKFLOW"
  echo "workflow_history_versionId_column=$HISTORY_HAS_VERSION"
  if [[ "$HISTORY_HAS_WORKFLOW" == 'YES' && "$HISTORY_HAS_VERSION" == 'YES' ]]; then
    psql_q "select to_jsonb(h)::text from \"$PG_SCHEMA\".workflow_history h where h.\"workflowId\"='$DASHBOARD_ID' and h.\"versionId\" in ('$DRAFT_VERSION_ID','$ACTIVE_VERSION_ID') order by h.\"versionId\";" > "$WORK/history.jsonl"
  else
    : > "$WORK/history.jsonl"
  fi
else
  : > "$WORK/history.jsonl"
fi

python3 - "$WORK/dashboard.export.json" "$WORK/entity.jsonl" "$WORK/history.jsonl" <<'PY'
import hashlib,json,sys
from pathlib import Path

def load_export(p):
    raw=json.loads(Path(p).read_text(encoding='utf-8'))
    return raw[0] if isinstance(raw,list) else raw

def load_jsonl(p):
    out=[]
    for line in Path(p).read_text(encoding='utf-8',errors='replace').splitlines():
        line=line.strip()
        if line:
            out.append(json.loads(line))
    return out

def as_obj(v):
    if isinstance(v,(dict,list)): return v
    if isinstance(v,str):
        try: return json.loads(v)
        except Exception: return v
    return v

def digest(v):
    return hashlib.sha256(json.dumps(v,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()).hexdigest()

def node_map(nodes):
    return {str(n.get('name')):n for n in (nodes or [])}

def backend_refs(nodes):
    hits=[]
    for n in nodes or []:
        params=n.get('parameters') or {}
        blob=json.dumps(params,ensure_ascii=False)
        refs=[]
        for token in ('finance_dashboard_read_model_v1','finance_dashboard_read_model_v2'):
            if token in blob: refs.append(token)
        if refs:
            hits.append((n.get('name'),','.join(refs)))
    return hits

exp=load_export(sys.argv[1])
entity_rows=load_jsonl(sys.argv[2])
history=load_jsonl(sys.argv[3])
entity=entity_rows[0] if entity_rows else {}
draft_id=str(exp.get('versionId') or '')
active_id=str(exp.get('activeVersionId') or '')
print(f'entity_versionId={entity.get("versionId","")}')
print(f'entity_activeVersionId={entity.get("activeVersionId","")}')
print(f'entity_updatedAt={entity.get("updatedAt","")}')
print(f'history_rows_selected={len(history)}')

by_version={str(r.get('versionId') or ''):r for r in history}
active=by_version.get(active_id)
draft_hist=by_version.get(draft_id)
print(f'active_history_row={"PRESENT" if active else "ABSENT"}')
print(f'draft_history_row={"PRESENT" if draft_hist else "ABSENT"}')

exp_nodes=as_obj(exp.get('nodes') or [])
exp_conn=as_obj(exp.get('connections') or {})
print(f'draft_nodes_sha={digest(exp_nodes)}')
print(f'draft_connections_sha={digest(exp_conn)}')
for name,refs in backend_refs(exp_nodes): print(f'draft_backend_ref node={name} refs={refs}')

if not active:
    print('dashboard_drift_class=ACTIVE_VERSION_CONTENT_UNAVAILABLE')
    print('N8N_MUTATION=NONE')
    print('DB_MUTATION=NONE')
    print('FRONTEND_MUTATION=NONE')
    print('UX022R3_DASHBOARD_DRIFT_FORENSIC=COMPLETE')
    raise SystemExit(0)

active_nodes=as_obj(active.get('nodes') or [])
active_conn=as_obj(active.get('connections') or {})
print(f'active_nodes_sha={digest(active_nodes)}')
print(f'active_connections_sha={digest(active_conn)}')
for name,refs in backend_refs(active_nodes): print(f'active_backend_ref node={name} refs={refs}')

same_nodes=digest(exp_nodes)==digest(active_nodes)
same_conn=digest(exp_conn)==digest(active_conn)
print(f'draft_active_nodes_equal={"YES" if same_nodes else "NO"}')
print(f'draft_active_connections_equal={"YES" if same_conn else "NO"}')

D=node_map(exp_nodes); A=node_map(active_nodes)
added=sorted(set(D)-set(A)); removed=sorted(set(A)-set(D)); changed=[]
for name in sorted(set(D)&set(A)):
    # Ignore purely visual position when classifying node behavior, but report full-content drift separately via SHA above.
    dn={k:v for k,v in D[name].items() if k not in ('position',)}
    an={k:v for k,v in A[name].items() if k not in ('position',)}
    if digest(dn)!=digest(an): changed.append(name)
print('draft_added_nodes=' + (','.join(added) if added else 'NONE'))
print('draft_removed_nodes=' + (','.join(removed) if removed else 'NONE'))
print('draft_behavior_changed_nodes=' + (','.join(changed) if changed else 'NONE'))

if same_nodes and same_conn:
    klass='METADATA_ONLY_DRIFT'
elif not added and not removed and not changed and same_conn:
    klass='VISUAL_POSITION_ONLY_DRIFT'
else:
    klass='CONTENT_DRIFT'
print(f'dashboard_drift_class={klass}')
print('N8N_MUTATION=NONE')
print('DB_MUTATION=NONE')
print('FRONTEND_MUTATION=NONE')
print('UX022R3_DASHBOARD_DRIFT_FORENSIC=PASS')
PY
