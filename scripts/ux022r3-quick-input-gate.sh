#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
N8N_CONTAINER="${MONEYTRACK_N8N_CONTAINER:-n8n}"
WORK="$(mktemp -d /tmp/ux022r3-quick-input-gate.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

cd "$ROOT"

echo '# Phase'
echo 'UX-022R3 quick-input ingress wrappers'
echo '# Gate'
echo 'READ_ONLY'

python3 -m py_compile scripts/ux022r3-generate-quick-input-workflow.py
python3 scripts/ux022r3-generate-quick-input-workflow.py --output "$WORK/quick-input.json"

python3 - "$WORK/quick-input.json" <<'PY'
import json, sys
from collections import Counter
from pathlib import Path

wf=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
assert wf['id']=='UX022QuickInput202608'
assert wf['active'] is False
nodes=wf['nodes']
webhooks=[n for n in nodes if n.get('type')=='n8n-nodes-base.webhook']
routes={(n['parameters'].get('httpMethod','GET'),n['parameters'].get('path')) for n in webhooks}
assert routes=={
    ('POST','api/v1/transaction/photo'),
    ('POST','api/v1/transaction/text'),
    ('POST','api/v1/transaction/voice'),
}
assert len(webhooks)==3

verify_nodes=[n for n in nodes if n.get('name','').endswith(' Verify')]
assert len(verify_nodes)==3
for node in verify_nodes:
    js=node['parameters'].get('jsCode','')
    assert 'moneytrackVerifyTelegramInitData' in js
    assert 'MONEYTRACK_TELEGRAM_AUTH_CONTRACT_VERSION' in js
    assert 'X-Telegram-Init-Data' in js

pg=[n for n in nodes if n.get('type')=='n8n-nodes-base.postgres']
assert len(pg)==3
for node in pg:
    q=node['parameters'].get('query','').lower()
    assert 'from moneytrack.app_users u' in q
    assert 'left join moneytrack.user_settings' in q
    assert 'where u.telegram_user_id' in q
    assert not any(token in q for token in ('insert into ','update moneytrack.','delete from ','finance_create_transaction_v1','receipt_ingest_v1'))

exec_nodes=[n for n in nodes if n.get('type')=='n8n-nodes-base.executeWorkflow']
targets=[n['parameters']['workflowId']['value'] for n in exec_nodes]
assert Counter(targets)==Counter({
    '5VC0EcFB21rwTfoI':1,
    'f5ioJKyPTupUMV9h':2,
    'Td7kvvrtqQK0FTJg':1,
})
assert all(n.get('onError')=='continueRegularOutput' for n in exec_nodes)
assert not any(n.get('type')=='n8n-nodes-base.telegram' for n in nodes)
assert not any(n.get('type')=='@n8n/n8n-nodes-langchain.openAi' for n in nodes)

by_name={n['name']:n for n in nodes}
assert "const binary = auth.binary || {};" in by_name['Photo Prepare']['parameters']['jsCode']
assert 'PHOTO_BINARY_MISSING' in by_name['Photo Prepare']['parameters']['jsCode']
assert "const binary = auth.binary || {};" in by_name['Voice Prepare']['parameters']['jsCode']
assert 'VOICE_BINARY_MISSING' in by_name['Voice Prepare']['parameters']['jsCode']
assert 'Voice Text Processor' in by_name
assert by_name['Voice Processor']['parameters']['workflowId']['value']=='Td7kvvrtqQK0FTJg'
assert by_name['Voice Text Processor']['parameters']['workflowId']['value']=='f5ioJKyPTupUMV9h'
print('quick_input_candidate_static=PASS')
PY

docker inspect "$N8N_CONTAINER" >/dev/null
docker exec "$N8N_CONTAINER" n8n export:workflow --all --output=/tmp/ux022r3-quick-gate-all.json >/dev/null
docker cp "$N8N_CONTAINER:/tmp/ux022r3-quick-gate-all.json" "$WORK/all.json" >/dev/null
docker exec "$N8N_CONTAINER" rm -f /tmp/ux022r3-quick-gate-all.json

python3 - "$WORK/all.json" "$WORK/quick-input.json" <<'PY'
import json,sys
from pathlib import Path

runtime=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
workflows=runtime if isinstance(runtime,list) else [runtime]
candidate=json.loads(Path(sys.argv[2]).read_text(encoding='utf-8'))
by_id={str(w.get('id')):w for w in workflows}
required={
    '5VC0EcFB21rwTfoI':'photo',
    'f5ioJKyPTupUMV9h':'text',
    'Td7kvvrtqQK0FTJg':'voice',
}
for wid,kind in required.items():
    wf=by_id.get(wid)
    assert wf is not None, f'{kind}_processor_missing'
    assert wf.get('active') is True, f'{kind}_processor_inactive'
print('quick_input_processors_active=PASS')

wanted={
    ('POST','api/v1/transaction/photo'),
    ('POST','api/v1/transaction/text'),
    ('POST','api/v1/transaction/voice'),
}
owners=[]
for wf in workflows:
    for node in wf.get('nodes',[]):
        if node.get('type')!='n8n-nodes-base.webhook':
            continue
        p=node.get('parameters') or {}
        key=(p.get('httpMethod','GET'),p.get('path'))
        if key in wanted:
            owners.append((key,wf.get('id'),wf.get('name'),wf.get('active')))
if owners:
    for row in owners:
        print('quick_route_collision=',row)
    raise SystemExit('QUICK_INPUT_ROUTE_COLLISION')
print('quick_input_routes_free=PASS')

# Match the Execute Workflow node version already used by the active MoneyTrack caller.
main=next((w for w in workflows if str(w.get('id'))=='DER2Lc3dT2afyQhy'),None)
assert main is not None, 'main_workflow_missing'
runtime_versions=set()
for node in main.get('nodes',[]):
    if node.get('type')!='n8n-nodes-base.executeWorkflow':
        continue
    target=((node.get('parameters') or {}).get('workflowId') or {})
    value=target.get('value') if isinstance(target,dict) else target
    if str(value) in required:
        runtime_versions.add(node.get('typeVersion'))
assert runtime_versions, 'processor_caller_node_version_missing'
candidate_versions={n.get('typeVersion') for n in candidate['nodes'] if n.get('type')=='n8n-nodes-base.executeWorkflow'}
assert len(candidate_versions)==1
assert candidate_versions.issubset(runtime_versions), f'execute_workflow_type_version_mismatch candidate={candidate_versions} runtime={runtime_versions}'
print('quick_input_execute_workflow_version=PASS version='+str(next(iter(candidate_versions))))
PY

echo 'QUICK_INPUT_INGRESS_GATE=PASS'
echo 'N8N_MUTATION=NONE'
echo 'DB_MUTATION=NONE'
echo 'FRONTEND_MUTATION=NONE'
