#!/usr/bin/env bash
set -euo pipefail

N8N_CONTAINER="${MONEYTRACK_N8N_CONTAINER:-n8n}"
WORK="$(mktemp -d /tmp/ux022r3-media-ingress.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

printf '%s\n' '# Phase' 'UX-022R3 media ingress topology forensic' '# Gate' 'READ_ONLY'
docker inspect "$N8N_CONTAINER" >/dev/null
docker exec "$N8N_CONTAINER" n8n export:workflow --all --output=/tmp/ux022r3-media-all.json >/dev/null
docker cp "$N8N_CONTAINER:/tmp/ux022r3-media-all.json" "$WORK/all.json" >/dev/null
docker exec "$N8N_CONTAINER" rm -f /tmp/ux022r3-media-all.json

python3 - "$WORK/all.json" <<'PY'
import json, sys
from collections import deque
from pathlib import Path

doc=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
workflows=doc if isinstance(doc,list) else [doc]
targets={
    'photo':'5VC0EcFB21rwTfoI',
    'voice':'Td7kvvrtqQK0FTJg',
}

def compact_params(params):
    keep={}
    for key,value in (params or {}).items():
        low=key.lower()
        if any(token in low for token in ('file','binary','data','resource','operation','input','audio','image','model')):
            keep[key]=value
    return keep

for kind,wid in targets.items():
    wf=next((w for w in workflows if str(w.get('id'))==wid),None)
    if not wf:
        print(f'media_workflow={kind} status=MISSING id={wid}')
        continue
    nodes={n.get('name'):n for n in wf.get('nodes',[]) if n.get('name')}
    conns=wf.get('connections') or {}
    triggers=[n for n in nodes.values() if 'executeWorkflowTrigger' in str(n.get('type') or '')]
    print(json.dumps({'media_workflow':kind,'id':wid,'name':wf.get('name'),'active':wf.get('active'),'trigger_names':[n.get('name') for n in triggers]},ensure_ascii=False))

    queue=deque((n.get('name'),0) for n in triggers)
    seen=set()
    while queue:
        name,depth=queue.popleft()
        if name in seen or depth>5: continue
        seen.add(name)
        node=nodes.get(name) or {}
        outs=[]
        for branch in (conns.get(name) or {}).get('main') or []:
            for edge in branch or []:
                target=edge.get('node')
                if target:
                    outs.append(target)
                    queue.append((target,depth+1))
        print(json.dumps({
            'kind':kind,'depth':depth,'node':name,'type':node.get('type'),
            'parameters':compact_params(node.get('parameters')),
            'next':outs,
        },ensure_ascii=False))

    print(f'# {kind} nodes mentioning binary/file/data')
    for node in nodes.values():
        params=node.get('parameters') or {}
        raw=json.dumps(params,ensure_ascii=False).lower()
        if any(token in raw for token in ('binary','telegram_file_id','fileid','inputdatafieldname','binarypropertyname')):
            print(json.dumps({'kind':kind,'node':node.get('name'),'type':node.get('type'),'parameters':compact_params(params)},ensure_ascii=False))

print('MEDIA_INGRESS_TOPOLOGY_FORENSIC=PASS')
PY

printf '%s\n' 'N8N_MUTATION=NONE' 'DB_MUTATION=NONE' 'FRONTEND_MUTATION=NONE'
