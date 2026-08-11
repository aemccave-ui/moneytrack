#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

N8N_CONTAINER="${MONEYTRACK_N8N_CONTAINER:-n8n}"
WORK="$(mktemp -d /tmp/ux022r3-photo-dedup-gate.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo '# Phase'
echo 'UX-022R3 MiniApp photo duplicate parity'
echo '# Gate'
echo 'READ_ONLY'

bash scripts/ux022-source-gate.sh

docker inspect "$N8N_CONTAINER" >/dev/null
python3 -m py_compile scripts/ux022r3-generate-quick-input-workflow.py scripts/ux022r3-patch-photo-dedup.py
python3 scripts/ux022r3-generate-quick-input-workflow.py --output "$WORK/quick.before.json"

docker exec "$N8N_CONTAINER" n8n export:workflow --id=5VC0EcFB21rwTfoI --output=/tmp/ux022r3-photo-dedup-photo.json >/dev/null
docker cp "$N8N_CONTAINER:/tmp/ux022r3-photo-dedup-photo.json" "$WORK/photo.before.json" >/dev/null
docker exec "$N8N_CONTAINER" rm -f /tmp/ux022r3-photo-dedup-photo.json

python3 scripts/ux022r3-patch-photo-dedup.py \
  --quick-before "$WORK/quick.before.json" \
  --photo-before "$WORK/photo.before.json" \
  --quick-after "$WORK/quick.after.json" \
  --photo-after "$WORK/photo.after.json"

python3 - "$WORK/quick.after.json" "$WORK/photo.after.json" <<'PY'
import json,sys
from pathlib import Path

def one(path):
    raw=json.loads(Path(path).read_text(encoding='utf-8'))
    return raw[0] if isinstance(raw,list) else raw

def node(wf,name):
    rows=[n for n in wf.get('nodes',[]) if n.get('name')==name]
    assert len(rows)==1,(name,len(rows))
    return rows[0]

quick=one(sys.argv[1])
photo=one(sys.argv[2])
assert quick['id']=='UX022QuickInput202608'
assert photo['id']=='5VC0EcFB21rwTfoI'

h=node(quick,'Photo Hash')
hcode=h['parameters']['jsCode']
assert "getBinaryDataBuffer(0, keys[0])" in hcode
assert "createHash('sha256')" in hcode
assert 'miniapp-sha256:' in hcode
assert 'binary' in hcode
print('miniapp_binary_sha256_before_ocr=PASS')

prep=node(quick,'Photo Prepare')['parameters']['jsCode']
assert "telegram_file_id: $('Photo Hash').first().json.photo_identity" in prep
print('miniapp_exact_identity_forwarded=PASS')

fmt=node(quick,'Photo Format')['parameters']['jsCode']
assert 'RECEIPT_DUPLICATE_EXACT' in fmt
assert 'RECEIPT_DUPLICATE_SEMANTIC' in fmt
assert 'http_status: 409' in fmt
assert 'row.message || fallback' in fmt
assert 'Повторная операция не создана' in fmt
print('miniapp_duplicate_message_contract=PASS')

exact=node(photo,'Check duplicate receipt')['parameters']['query'].lower()
assert 'r.user_id =' in exact
assert 'r.telegram_file_id' in exact
print('exact_duplicate_user_scoped=PASS')

semantic=node(photo,'Check semantic duplicate receipt')['parameters']['query'].lower()
for token in ('receipt_items','item_count','amount_signature','receipt_date','total_amount','upper(r.currency)'):
    assert token in semantic,token
assert 'receipt_fingerprint' in semantic
print('semantic_duplicate_content_signature=PASS')

conns=quick['connections']
true_branch=conns['Photo Auth OK']['main'][0]
assert len(true_branch)==1 and true_branch[0]['node']=='Photo Hash'
assert conns['Photo Hash']['main'][0][0]['node']=='Photo User Context'
print('photo_hash_topology=PASS')

# No public route or processor identity changes.
webhooks=[n for n in quick['nodes'] if n.get('type')=='n8n-nodes-base.webhook']
routes={(n['parameters'].get('httpMethod','GET'),n['parameters'].get('path')) for n in webhooks}
assert ('POST','api/v1/transaction/photo') in routes
proc=node(quick,'Photo Processor')
assert proc['parameters']['workflowId']['value']=='5VC0EcFB21rwTfoI'
print('quick_input_route_and_processor_stable=PASS')

print('UX022R3_PHOTO_DEDUP_STATIC=PASS')
PY

echo 'N8N_MUTATION=NONE'
echo 'DB_MUTATION=NONE'
echo 'FRONTEND_MUTATION=NONE'
echo 'UX022R3_PHOTO_DEDUP_GATE=PASS'
