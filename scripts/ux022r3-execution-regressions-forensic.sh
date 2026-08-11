#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

N8N_CONTAINER="${MONEYTRACK_N8N_CONTAINER:-n8n}"
WORK="$(mktemp -d /tmp/ux022r3-execution-regressions.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

container_tmp_rm() {
  local remote="$1"
  docker exec -u 0 "$N8N_CONTAINER" rm -f "$remote" >/dev/null 2>&1 || true
}

export_all() {
  local remote="/tmp/ux022r3-exec-forensic-$$-all.json"
  container_tmp_rm "$remote"
  docker exec "$N8N_CONTAINER" n8n export:workflow --all --output="$remote" >/dev/null
  docker cp "$N8N_CONTAINER:$remote" "$WORK/all.json" >/dev/null
  container_tmp_rm "$remote"
}

echo '# Phase'
echo 'UX-022R3 execution-level regressions forensic: photo + transactions adapter'
echo '# Gate'
echo 'READ_ONLY'
echo "HEAD=$(git rev-parse HEAD)"

docker inspect "$N8N_CONTAINER" >/dev/null
export_all

python3 - "$WORK/all.json" "$WORK/target-workflow-ids.txt" <<'PY'
import json,sys
from pathlib import Path

raw=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
workflows=raw if isinstance(raw,list) else [raw]

def routes(wf):
    out=[]
    for n in wf.get('nodes') or []:
        if n.get('type')!='n8n-nodes-base.webhook':
            continue
        p=n.get('parameters') or {}
        out.append((str(p.get('httpMethod','GET')).upper(),str(p.get('path') or ''),n.get('name')))
    return out

owners=[]
for wf in workflows:
    for method,path,node_name in routes(wf):
        if method=='GET' and path=='api/v1/transactions':
            owners.append(wf)
            print('transactions_route_owner=' + json.dumps({
                'id':wf.get('id'),'name':wf.get('name'),'active':wf.get('active'),
                'versionId':wf.get('versionId'),'activeVersionId':wf.get('activeVersionId'),
                'webhook_node':node_name,
            },ensure_ascii=False))

if not owners:
    print('transactions_route_owner=MISSING')

needles=('api_transactions_read_model_v2','api_transactions_read_model_v1','selected_account_ids','include_descendants','income','expense','summary_currency')
for wf in owners:
    for n in wf.get('nodes') or []:
        params=n.get('parameters') or {}
        text=json.dumps(params,ensure_ascii=False)
        if any(token in text for token in needles):
            compact={
                'workflow_id':wf.get('id'),'workflow':wf.get('name'),'node':n.get('name'),
                'type':n.get('type'),'onError':n.get('onError'),'parameters':params,
            }
            print('transactions_adapter_node='+json.dumps(compact,ensure_ascii=False))

for wid,label in [('UX022QuickInput202608','quick'),('5VC0EcFB21rwTfoI','photo')]:
    wf=next((w for w in workflows if str(w.get('id'))==wid),None)
    if wf:
        print(f'{label}_workflow=' + json.dumps({
            'id':wf.get('id'),'name':wf.get('name'),'active':wf.get('active'),
            'versionId':wf.get('versionId'),'activeVersionId':wf.get('activeVersionId')
        },ensure_ascii=False))
    else:
        print(f'{label}_workflow=MISSING id={wid}')

ids=['UX022QuickInput202608','5VC0EcFB21rwTfoI']+[str(w.get('id')) for w in owners if w.get('id')]
Path(sys.argv[2]).write_text('\n'.join(dict.fromkeys(ids))+'\n',encoding='utf-8')
PY

echo '# n8n execution store'
DB_TYPE="$(docker exec "$N8N_CONTAINER" sh -c 'printf "%s" "${DB_TYPE:-sqlite}"' 2>/dev/null || true)"
echo "n8n_db_type=${DB_TYPE:-unknown}"

SQLITE_REMOTE=''
for candidate in /home/node/.n8n/database.sqlite /root/.n8n/database.sqlite; do
  if docker exec "$N8N_CONTAINER" test -f "$candidate" 2>/dev/null; then
    SQLITE_REMOTE="$candidate"
    break
  fi
done

if [[ -n "$SQLITE_REMOTE" ]]; then
  echo "n8n_execution_store=SQLITE path=$SQLITE_REMOTE"
  docker cp "$N8N_CONTAINER:$SQLITE_REMOTE" "$WORK/n8n.sqlite" >/dev/null
  python3 - "$WORK/n8n.sqlite" "$WORK/target-workflow-ids.txt" <<'PY'
import json,re,sqlite3,sys
from pathlib import Path

path=Path(sys.argv[1])
targets={x.strip() for x in Path(sys.argv[2]).read_text(encoding='utf-8').splitlines() if x.strip()}
con=sqlite3.connect(f'file:{path}?mode=ro',uri=True)
con.row_factory=sqlite3.Row

def tables():
    return {r[0] for r in con.execute("select name from sqlite_master where type='table'")}

def cols(table):
    return [r[1] for r in con.execute(f'pragma table_info("{table}")')]

t=tables()
print('n8n_execution_tables=' + ','.join(sorted(x for x in t if 'execution' in x.lower())))

entity=next((x for x in ('execution_entity','executionEntity') if x in t),None)
data_table=next((x for x in ('execution_data','executionData') if x in t),None)
if not entity:
    print('execution_entity=NOT_FOUND')
    raise SystemExit(0)

c=cols(entity)
print('execution_entity_columns='+','.join(c))
id_col='id' if 'id' in c else None
wf_col='workflowId' if 'workflowId' in c else 'workflow_id' if 'workflow_id' in c else None
status_col='status' if 'status' in c else None
started_col='startedAt' if 'startedAt' in c else 'started_at' if 'started_at' in c else None
stopped_col='stoppedAt' if 'stoppedAt' in c else 'stopped_at' if 'stopped_at' in c else None
mode_col='mode' if 'mode' in c else None
if not id_col or not wf_col:
    print('execution_entity_contract=UNSUPPORTED')
    raise SystemExit(0)

select_cols=[id_col,wf_col]+[x for x in (status_col,started_col,stopped_col,mode_col) if x]
ph=','.join('?' for _ in targets)
rows=list(con.execute(
    f'SELECT {",".join(chr(34)+x+chr(34) for x in select_cols)} FROM "{entity}" '
    f'WHERE "{wf_col}" IN ({ph}) ORDER BY CAST("{id_col}" AS INTEGER) DESC LIMIT 50',
    tuple(targets)
)) if targets else []
print(f'target_execution_count={len(rows)}')
for r in rows:
    print('execution=' + json.dumps({k:r[k] for k in r.keys()},ensure_ascii=False,default=str))

if not data_table:
    print('execution_data=NOT_FOUND')
    raise SystemExit(0)

dc=cols(data_table)
print('execution_data_columns='+','.join(dc))
exec_col='executionId' if 'executionId' in dc else 'execution_id' if 'execution_id' in dc else None
payload_col='data' if 'data' in dc else None
if not exec_col or not payload_col:
    print('execution_data_contract=UNSUPPORTED')
    raise SystemExit(0)

wanted=[str(r[id_col]) for r in rows[:30]]
if not wanted:
    raise SystemExit(0)
ph=','.join('?' for _ in wanted)
for r in con.execute(f'SELECT "{exec_col}","{payload_col}" FROM "{data_table}" WHERE "{exec_col}" IN ({ph})',wanted):
    eid=str(r[0]); raw=str(r[1] or '')
    low=raw.lower()
    markers=['domain_error','error','lastnodeexecuted','check semantic duplicate receipt','check duplicate receipt','photo hash','photo processor','postgres']
    positions=[low.find(m) for m in markers if low.find(m)>=0]
    if not positions:
        continue
    pos=min(positions)
    start=max(0,pos-700); end=min(len(raw),pos+2600)
    snippet=raw[start:end].replace('\n',' ')
    snippet=re.sub(r'(?i)(password|token|authorization|initdata)[^,}\]]{0,300}',r'\1=<redacted>',snippet)
    print(f'execution_data_hint id={eid} snippet={snippet}')
PY
else
  echo 'n8n_execution_store=SQLITE_NOT_FOUND'
fi

# PostgreSQL-mode fallback. It deliberately prints no password/connection secret.
if [[ "${DB_TYPE:-}" == 'postgresdb' || "${DB_TYPE:-}" == 'postgres' ]]; then
  PG_HOST="$(docker exec "$N8N_CONTAINER" sh -c 'printf "%s" "${DB_POSTGRESDB_HOST:-}"' 2>/dev/null || true)"
  PG_PORT="$(docker exec "$N8N_CONTAINER" sh -c 'printf "%s" "${DB_POSTGRESDB_PORT:-5432}"' 2>/dev/null || true)"
  PG_DB="$(docker exec "$N8N_CONTAINER" sh -c 'printf "%s" "${DB_POSTGRESDB_DATABASE:-n8n}"' 2>/dev/null || true)"
  PG_USER="$(docker exec "$N8N_CONTAINER" sh -c 'printf "%s" "${DB_POSTGRESDB_USER:-}"' 2>/dev/null || true)"
  PG_SCHEMA="$(docker exec "$N8N_CONTAINER" sh -c 'printf "%s" "${DB_POSTGRESDB_SCHEMA:-public}"' 2>/dev/null || true)"
  PG_PASS="$(docker exec "$N8N_CONTAINER" sh -c 'printf "%s" "${DB_POSTGRESDB_PASSWORD:-}"' 2>/dev/null || true)"
  echo "n8n_postgres_host_resolvable=$([[ -n "$PG_HOST" ]] && echo YES || echo NO)"
  if [[ -n "$PG_HOST" ]] && docker inspect "$PG_HOST" >/dev/null 2>&1 && docker exec "$PG_HOST" sh -c 'command -v psql >/dev/null' 2>/dev/null; then
    echo 'n8n_execution_store=POSTGRES_CONTAINER_READABLE'
    docker exec -e PGPASSWORD="$PG_PASS" "$PG_HOST" psql -X -q -v ON_ERROR_STOP=1 \
      -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" <<SQL || true
\pset pager off
\echo '# execution tables'
select table_name from information_schema.tables where table_schema='$PG_SCHEMA' and lower(table_name) like '%execution%' order by table_name;
\echo '# execution_entity columns'
select column_name from information_schema.columns where table_schema='$PG_SCHEMA' and table_name='execution_entity' order by ordinal_position;
\echo '# recent target executions'
select id,"workflowId",status,"startedAt","stoppedAt",mode
from "$PG_SCHEMA"."execution_entity"
where "workflowId" in ('UX022QuickInput202608','5VC0EcFB21rwTfoI')
order by id desc limit 40;
\echo '# recent execution error hints'
select d."executionId", left(d.data::text,3500)
from "$PG_SCHEMA"."execution_data" d
join "$PG_SCHEMA"."execution_entity" e on e.id=d."executionId"
where e."workflowId" in ('UX022QuickInput202608','5VC0EcFB21rwTfoI')
  and lower(d.data::text) like '%error%'
order by d."executionId" desc limit 12;
SQL
  else
    echo 'n8n_execution_store=POSTGRES_DIRECT_QUERY_UNAVAILABLE'
  fi
fi

echo '# n8n recent focused logs'
docker logs --since 8h "$N8N_CONTAINER" 2>&1 \
  | grep -Ei 'execution|error|receipt|duplicate|semantic|photo|postgres|invalid input|query|workflow' \
  | tail -n 240 || true

echo 'N8N_MUTATION=NONE'
echo 'DB_MUTATION=NONE'
echo 'FRONTEND_MUTATION=NONE'
echo 'UX022R3_EXECUTION_REGRESSIONS_FORENSIC=PASS'
