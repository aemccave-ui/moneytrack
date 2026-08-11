#!/usr/bin/env bash
set -euo pipefail

N8N_CONTAINER="${MONEYTRACK_N8N_CONTAINER:-n8n}"
WORK="$(mktemp -d /tmp/ux022r3-media-binary.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo '# Phase'
echo 'UX-022R3 media binary contract forensic'
echo '# Gate'
echo 'READ_ONLY'

docker inspect "$N8N_CONTAINER" >/dev/null

docker exec "$N8N_CONTAINER" n8n export:workflow --all --output=/tmp/ux022r3-all-workflows.json >/dev/null
docker cp "$N8N_CONTAINER:/tmp/ux022r3-all-workflows.json" "$WORK/all.json" >/dev/null
docker exec "$N8N_CONTAINER" rm -f /tmp/ux022r3-all-workflows.json

python3 - "$WORK/all.json" <<'PY'
import json, sys
from pathlib import Path

doc=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
workflows=doc if isinstance(doc,list) else [doc]
ids={
    'photo':'5VC0EcFB21rwTfoI',
    'voice':'Td7kvvrtqQK0FTJg',
}
targets={
    'photo':{
        'Preserve Photo Binary',
        'Restore Photo Binary',
        'Normalize image binary',
        'If3',
        'Get a file',
    },
    'voice':{
        'Normalize Voice Input',
        'telegram_file_id',
        'Get voice file',
        'Normalize voice binary',
        'OpenAI Audio Transcription',
    },
}

for kind,wid in ids.items():
    wf=next((w for w in workflows if str(w.get('id'))==wid),None)
    if not wf:
        print(f'media_binary_contract={kind}:MISSING_WORKFLOW')
        continue
    print(json.dumps({'kind':kind,'workflow_id':wid,'workflow':wf.get('name'),'active':wf.get('active')},ensure_ascii=False))
    by_name={str(n.get('name')):n for n in wf.get('nodes',[])}
    conns=wf.get('connections') or {}
    for name in targets[kind]:
        node=by_name.get(name)
        if not node:
            print(json.dumps({'kind':kind,'node':name,'missing':True},ensure_ascii=False))
            continue
        params=node.get('parameters') or {}
        compact={
            'kind':kind,
            'node':name,
            'type':node.get('type'),
            'parameters':params,
            'next':[
                c.get('node')
                for group in (conns.get(name,{}).get('main') or [])
                for c in (group or [])
            ],
        }
        print(json.dumps(compact,ensure_ascii=False))

print('MEDIA_BINARY_CONTRACT_FORENSIC=PASS')
PY

echo 'N8N_MUTATION=NONE'
echo 'DB_MUTATION=NONE'
echo 'FRONTEND_MUTATION=NONE'
