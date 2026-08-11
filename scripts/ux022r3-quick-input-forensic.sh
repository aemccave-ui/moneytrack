#!/usr/bin/env bash
set -euo pipefail

N8N_CONTAINER="${MONEYTRACK_N8N_CONTAINER:-n8n}"
WORK="$(mktemp -d /tmp/ux022r3-quick-input.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo '# Phase'
echo 'UX-022R3 quick-input runtime forensic'
echo '# Gate'
echo 'READ_ONLY'

docker inspect "$N8N_CONTAINER" >/dev/null

docker exec "$N8N_CONTAINER" n8n export:workflow --all --output=/tmp/ux022r3-all-workflows.json >/dev/null
docker cp "$N8N_CONTAINER:/tmp/ux022r3-all-workflows.json" "$WORK/all.json" >/dev/null
docker exec "$N8N_CONTAINER" rm -f /tmp/ux022r3-all-workflows.json

python3 - "$WORK/all.json" <<'PY'
import json, sys
from pathlib import Path

path=Path(sys.argv[1])
doc=json.loads(path.read_text(encoding='utf-8'))
workflows=doc if isinstance(doc,list) else [doc]
paths={'api/v1/transaction/photo','api/v1/transaction/text','api/v1/transaction/voice'}
processors={'5VC0EcFB21rwTfoI','f5ioJKyPTupUMV9h'}
found=[]
for wf in workflows:
    for node in wf.get('nodes',[]):
        params=node.get('parameters') or {}
        route=params.get('path')
        if route in paths:
            found.append((route,wf.get('id'),wf.get('name'),node.get('name'),params.get('httpMethod','GET'),wf.get('active')))

for route in sorted(paths):
    rows=[row for row in found if row[0]==route]
    if rows:
        for row in rows:
            print('quick_route=FOUND path=%s workflow_id=%s workflow=%r node=%r method=%s active=%s'%row)
    else:
        print(f'quick_route=MISSING path={route}')

print('# Processor trigger evidence')
for wf in workflows:
    name=str(wf.get('name') or '')
    if wf.get('id') in processors or 'Transaction Processor' in name:
        triggers=[]
        for node in wf.get('nodes',[]):
            typ=str(node.get('type') or '')
            if 'executeWorkflowTrigger' in typ or 'webhook' in typ.lower() or 'telegramTrigger' in typ:
                triggers.append({'name':node.get('name'),'type':typ,'parameters':node.get('parameters')})
        print(json.dumps({'id':wf.get('id'),'name':name,'active':wf.get('active'),'triggers':triggers},ensure_ascii=False))

missing=sorted(paths-{row[0] for row in found})
print('QUICK_INPUT_ROUTES_PRESENT=' + ('PASS' if not missing else 'FAIL'))
print('missing_routes=' + ','.join(missing))
PY

echo 'N8N_MUTATION=NONE'
echo 'DB_MUTATION=NONE'
echo 'FRONTEND_MUTATION=NONE'
