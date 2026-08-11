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
import json
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
doc = json.loads(path.read_text(encoding='utf-8'))
workflows = doc if isinstance(doc, list) else [doc]
paths = {'api/v1/transaction/photo', 'api/v1/transaction/text', 'api/v1/transaction/voice'}
processors = {
    'photo': '5VC0EcFB21rwTfoI',
    'text': 'f5ioJKyPTupUMV9h',
    'voice': 'Td7kvvrtqQK0FTJg',
}
processor_ids = set(processors.values())
found = []

for wf in workflows:
    for node in wf.get('nodes', []):
        params = node.get('parameters') or {}
        route = params.get('path')
        if route in paths:
            found.append((route, wf.get('id'), wf.get('name'), node.get('name'), params.get('httpMethod', 'GET'), wf.get('active')))

for route in sorted(paths):
    rows = [row for row in found if row[0] == route]
    if rows:
        for row in rows:
            print('quick_route=FOUND path=%s workflow_id=%s workflow=%r node=%r method=%s active=%s' % row)
    else:
        print(f'quick_route=MISSING path={route}')

print('# Processor trigger evidence')
by_id = {str(wf.get('id')): wf for wf in workflows}
for kind, workflow_id in processors.items():
    wf = by_id.get(workflow_id)
    if not wf:
        print(f'processor={kind} id={workflow_id} status=MISSING')
        continue
    triggers = []
    for node in wf.get('nodes', []):
        typ = str(node.get('type') or '')
        if 'executeWorkflowTrigger' in typ or 'webhook' in typ.lower() or 'telegramTrigger' in typ:
            triggers.append({'name': node.get('name'), 'type': typ, 'parameters': node.get('parameters')})
    print(json.dumps({'kind': kind, 'id': wf.get('id'), 'name': wf.get('name'), 'active': wf.get('active'), 'triggers': triggers}, ensure_ascii=False))

print('# Existing Execute Workflow callers for processors')

def compact(value, limit=1800):
    text = json.dumps(value, ensure_ascii=False, separators=(',', ':'))
    return text if len(text) <= limit else text[:limit] + '…'

for wf in workflows:
    node_map = {str(node.get('name')): node for node in wf.get('nodes', [])}
    reverse = {}
    for source_name, outputs in (wf.get('connections') or {}).items():
        for channel in (outputs or {}).values():
            for branch in channel or []:
                for edge in branch or []:
                    target = str(edge.get('node') or '')
                    if target:
                        reverse.setdefault(target, []).append(str(source_name))
    for node in wf.get('nodes', []):
        params = node.get('parameters') or {}
        raw = json.dumps(params, ensure_ascii=False)
        hits = [(kind, workflow_id) for kind, workflow_id in processors.items() if workflow_id in raw]
        if not hits:
            continue
        print('processor_caller=' + compact({
            'workflow_id': wf.get('id'),
            'workflow': wf.get('name'),
            'active': wf.get('active'),
            'node': node.get('name'),
            'type': node.get('type'),
            'targets': hits,
            'parameters': params,
        }))
        for predecessor_name in reverse.get(str(node.get('name')), []):
            predecessor = node_map.get(predecessor_name) or {}
            print('processor_caller_predecessor=' + compact({
                'workflow_id': wf.get('id'),
                'caller': node.get('name'),
                'node': predecessor_name,
                'type': predecessor.get('type'),
                'parameters': predecessor.get('parameters') or {},
            }))

print('# Processor input references')
json_key_re = re.compile(r"\$json(?:\.([A-Za-z_][A-Za-z0-9_]*)|\[['\"]([^'\"]+)['\"]\])")
binary_key_re = re.compile(r"\$binary(?:\.([A-Za-z_][A-Za-z0-9_]*)|\[['\"]([^'\"]+)['\"]\])")

for kind, workflow_id in processors.items():
    wf = by_id.get(workflow_id)
    if not wf:
        continue
    raw_parts = []
    trigger_names = []
    for node in wf.get('nodes', []):
        typ = str(node.get('type') or '')
        if 'executeWorkflowTrigger' in typ:
            trigger_names.append(str(node.get('name') or ''))
        raw_parts.append(json.dumps(node.get('parameters') or {}, ensure_ascii=False))
    raw = '\n'.join(raw_parts)
    json_keys = sorted({a or b for a, b in json_key_re.findall(raw) if a or b})
    binary_keys = sorted({a or b for a, b in binary_key_re.findall(raw) if a or b})
    trigger_refs = []
    for node in wf.get('nodes', []):
        params_text = json.dumps(node.get('parameters') or {}, ensure_ascii=False)
        if any(name and (f"$('" + name + "')") in params_text for name in trigger_names):
            trigger_refs.append({
                'node': node.get('name'),
                'type': node.get('type'),
                'parameters': node.get('parameters') or {},
            })
    print('processor_input_contract=' + compact({
        'kind': kind,
        'workflow_id': workflow_id,
        'json_keys_seen': json_keys,
        'binary_keys_seen': binary_keys,
        'trigger_names': trigger_names,
        'trigger_referencing_nodes': trigger_refs[:12],
    }, 5000))

missing = sorted(paths - {row[0] for row in found})
print('QUICK_INPUT_ROUTES_PRESENT=' + ('PASS' if not missing else 'FAIL'))
print('missing_routes=' + ','.join(missing))
print('QUICK_INPUT_CONTRACT_FORENSIC=PASS')
PY

echo 'N8N_MUTATION=NONE'
echo 'DB_MUTATION=NONE'
echo 'FRONTEND_MUTATION=NONE'
