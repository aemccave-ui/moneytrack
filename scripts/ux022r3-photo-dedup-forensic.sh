#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/ux022-db-runtime.sh"

N8N_CONTAINER="${MONEYTRACK_N8N_CONTAINER:-n8n}"
WORK="$(mktemp -d /tmp/ux022r3-photo-dedup.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PHOTO_ID='5VC0EcFB21rwTfoI'
MAIN_ID='DER2Lc3dT2afyQhy'
QUICK_ID='UX022QuickInput202608'

echo '# Phase'
echo 'UX-022R3 photo receipt dedup forensic'
echo '# Gate'
echo 'READ_ONLY'

docker inspect "$N8N_CONTAINER" >/dev/null
ux022_db_init
echo "db_runtime_mode=$UX022_DB_MODE"

docker exec "$N8N_CONTAINER" n8n export:workflow --all --output=/tmp/ux022r3-photo-dedup-all.json >/dev/null
docker cp "$N8N_CONTAINER:/tmp/ux022r3-photo-dedup-all.json" "$WORK/all.json" >/dev/null
docker exec "$N8N_CONTAINER" rm -f /tmp/ux022r3-photo-dedup-all.json

python3 - "$WORK/all.json" <<'PY'
import json, re, sys
from collections import deque
from pathlib import Path

raw=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
workflows=raw if isinstance(raw,list) else [raw]
ids={
    'main':'DER2Lc3dT2afyQhy',
    'photo':'5VC0EcFB21rwTfoI',
    'quick':'UX022QuickInput202608',
}

for kind,wid in ids.items():
    wf=next((w for w in workflows if str(w.get('id'))==wid),None)
    if not wf:
        print(f'{kind}_workflow=MISSING id={wid}')
        continue
    print(json.dumps({
        'kind':kind,
        'id':wid,
        'name':wf.get('name'),
        'active':wf.get('active'),
        'createdAt':wf.get('createdAt'),
        'updatedAt':wf.get('updatedAt'),
        'versionId':wf.get('versionId'),
        'activeVersionId':wf.get('activeVersionId'),
        'nodes':len(wf.get('nodes',[])),
    },ensure_ascii=False))

    by_name={str(n.get('name')):n for n in wf.get('nodes',[])}
    conns=wf.get('connections') or {}
    graph={name:[] for name in by_name}
    reverse={name:[] for name in by_name}
    for src,spec in conns.items():
        for branch in (spec.get('main') or []):
            for edge in (branch or []):
                dst=str(edge.get('node'))
                graph.setdefault(src,[]).append(dst)
                reverse.setdefault(dst,[]).append(src)

    def text(node):
        return json.dumps(node.get('parameters') or {},ensure_ascii=False,sort_keys=True)

    pattern=re.compile(r'duplic|hash|fingerprint|telegram_file_id|receipt_ingest|already|повтор|загруж',re.I)
    relevant=[]
    for name,node in by_name.items():
        if pattern.search(name) or pattern.search(text(node)):
            relevant.append(name)

    print(f'{kind}_dedup_relevant_nodes={len(relevant)}')
    for name in sorted(relevant):
        node=by_name[name]
        params=node.get('parameters') or {}
        compact={
            'kind':kind,
            'node':name,
            'type':node.get('type'),
            'prev':reverse.get(name,[]),
            'next':graph.get(name,[]),
        }
        # Include the fields that can define the dedup contract without dumping unrelated secrets.
        for key in ('query','jsCode','conditions','workflowId','workflowInputs','responseBody'):
            if key in params:
                compact[key]=params[key]
        print(json.dumps(compact,ensure_ascii=False))

    if kind=='photo':
        triggers=[name for name,node in by_name.items() if 'trigger' in str(node.get('type','')).lower()]
        targets=[name for name in ('Build receipt fingerprint','Insert transaction') if name in by_name]
        print('photo_triggers='+json.dumps(triggers,ensure_ascii=False))
        for target in targets:
            best=None
            for start in triggers:
                q=deque([(start,[start])]); seen={start}
                while q:
                    cur,path=q.popleft()
                    if cur==target:
                        if best is None or len(path)<len(best): best=path
                        break
                    for nxt in graph.get(cur,[]):
                        if nxt not in seen:
                            seen.add(nxt); q.append((nxt,path+[nxt]))
            print(f'photo_shortest_path_to_{target}='+json.dumps(best,ensure_ascii=False))

    if kind=='quick':
        for name in ('Photo Prepare','Photo Processor'):
            node=by_name.get(name)
            if node:
                print(json.dumps({
                    'kind':'quick-photo-contract',
                    'node':name,
                    'type':node.get('type'),
                    'parameters':node.get('parameters') or {},
                },ensure_ascii=False))

print('N8N_DEDUP_TOPOLOGY_FORENSIC=PASS')
PY

cat > "$WORK/db.sql" <<'SQL'
\set ON_ERROR_STOP on
\pset format unaligned
\pset fieldsep '|'
\pset tuples_only on

select 'receipt_columns=' || string_agg(column_name, ',' order by ordinal_position)
from information_schema.columns
where table_schema='moneytrack' and table_name='receipts';

select 'recent_receipt=' || concat_ws('|',
  r.id::text,
  r.user_id::text,
  coalesce(r.transaction_id::text,''),
  coalesce(r.telegram_file_id,''),
  coalesce(r.receipt_fingerprint,''),
  coalesce(r.shop_name,''),
  coalesce(r.total_amount::text,''),
  coalesce(r.currency,''),
  coalesce(r.receipt_date::text,'')
)
from moneytrack.receipts r
order by r.id desc
limit 30;

select 'duplicate_fingerprint=' || concat_ws('|',
  user_id::text,
  receipt_fingerprint,
  count(*)::text,
  min(id)::text,
  max(id)::text
)
from moneytrack.receipts
where nullif(btrim(receipt_fingerprint),'') is not null
group by user_id,receipt_fingerprint
having count(*) > 1
order by max(id) desc
limit 20;

select 'null_identity_receipts=' || count(*)::text
from moneytrack.receipts
where nullif(btrim(telegram_file_id),'') is null
  and nullif(btrim(receipt_fingerprint),'') is null;
SQL
ux022_db_psql_file "$WORK/db.sql"

echo 'DB_DEDUP_FORENSIC=PASS'
echo 'N8N_MUTATION=NONE'
echo 'DB_MUTATION=NONE'
echo 'FRONTEND_MUTATION=NONE'
echo 'UX022R3_PHOTO_DEDUP_FORENSIC=PASS'
