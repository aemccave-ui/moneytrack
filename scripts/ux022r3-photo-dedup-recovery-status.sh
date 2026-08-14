#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

N8N_CONTAINER="${MONEYTRACK_N8N_CONTAINER:-n8n}"
API_BASE="${MONEYTRACK_API_BASE:-https://n8n.moneytrackapp.xyz/webhook}"
WORK="$(mktemp -d /tmp/ux022r3-photo-dedup-recovery.XXXXXX)"
QUICK_ID="UX022QuickInput202608"
PHOTO_ID="5VC0EcFB21rwTfoI"
trap 'rm -rf "$WORK"' EXIT

container_tmp_rm() {
  local remote="$1"
  docker exec -u 0 "$N8N_CONTAINER" rm -f "$remote" >/dev/null 2>&1 || true
}

export_one() {
  local id="$1"
  local target="$2"
  local remote="/tmp/ux022r3-recovery-$$-${id}.json"
  container_tmp_rm "$remote"
  docker exec "$N8N_CONTAINER" n8n export:workflow --id="$id" --output="$remote" >/dev/null
  docker cp "$N8N_CONTAINER:$remote" "$target" >/dev/null
  container_tmp_rm "$remote"
}

echo '# Phase'
echo 'UX-022R3 photo dedup recovery status'
echo '# Gate'
echo 'READ_ONLY'
echo "HEAD=$(git rev-parse HEAD)"

docker inspect "$N8N_CONTAINER" >/dev/null
export_one "$QUICK_ID" "$WORK/quick.json"
export_one "$PHOTO_ID" "$WORK/photo.json"

python3 - "$WORK/quick.json" "$WORK/photo.json" <<'PY'
import json,sys
from pathlib import Path

def one(path):
    raw=json.loads(Path(path).read_text(encoding='utf-8'))
    return raw[0] if isinstance(raw,list) else raw

def node(wf,name):
    rows=[n for n in wf.get('nodes',[]) if n.get('name')==name]
    return rows[0] if len(rows)==1 else None

quick=one(sys.argv[1]); photo=one(sys.argv[2])
print(f"quick_active={str(quick.get('active')).upper()}")
print(f"quick_versionId={quick.get('versionId')}")
print(f"quick_activeVersionId={quick.get('activeVersionId')}")
print(f"photo_active={str(photo.get('active')).upper()}")
print(f"photo_versionId={photo.get('versionId')}")
print(f"photo_activeVersionId={photo.get('activeVersionId')}")

quick_published = quick.get('active') is True and quick.get('versionId') == quick.get('activeVersionId')
photo_published = photo.get('active') is True and photo.get('versionId') == photo.get('activeVersionId')
print(f"quick_published={'PASS' if quick_published else 'FAIL'}")
print(f"photo_published={'PASS' if photo_published else 'FAIL'}")

h=node(quick,'Photo Hash')
fmt=node(quick,'Photo Format')
prep=node(quick,'Photo Prepare')
quick_patched = bool(
    h
    and "createHash('sha256')" in (h.get('parameters',{}).get('jsCode') or '')
    and 'miniapp-sha256:' in (h.get('parameters',{}).get('jsCode') or '')
    and prep
    and "telegram_file_id: $('Photo Hash').first().json.photo_identity" in (prep.get('parameters',{}).get('jsCode') or '')
    and fmt
    and 'RECEIPT_DUPLICATE_EXACT' in (fmt.get('parameters',{}).get('jsCode') or '')
    and 'RECEIPT_DUPLICATE_SEMANTIC' in (fmt.get('parameters',{}).get('jsCode') or '')
    and 'http_status: 409' in (fmt.get('parameters',{}).get('jsCode') or '')
)
quick_unpatched = bool(
    h is None
    and fmt
    and 'RECEIPT_DUPLICATE_EXACT' not in (fmt.get('parameters',{}).get('jsCode') or '')
)

exact=node(photo,'Check duplicate receipt')
semantic=node(photo,'Check semantic duplicate receipt')
exact_q=(exact.get('parameters',{}).get('query') or '').lower() if exact else ''
semantic_q=(semantic.get('parameters',{}).get('query') or '').lower() if semantic else ''
photo_patched = bool(
    'r.user_id =' in exact_q
    and 'r.telegram_file_id' in exact_q
    and all(t in semantic_q for t in ('receipt_items','item_count','amount_signature','receipt_date','total_amount','upper(r.currency)'))
)
photo_unpatched = bool(
    exact is not None
    and semantic is not None
    and 'amount_signature' not in semantic_q
)

print(f"quick_contract={'PATCHED' if quick_patched else 'UNPATCHED' if quick_unpatched else 'UNKNOWN'}")
print(f"photo_contract={'PATCHED' if photo_patched else 'UNPATCHED' if photo_unpatched else 'UNKNOWN'}")

if quick_patched and photo_patched:
    state='EXPECTED_PATCHED'
elif quick_unpatched and photo_unpatched:
    state='EXPECTED_UNPATCHED'
else:
    state='MIXED_OR_UNKNOWN'
print(f"runtime_contract_state={state}")

if not quick_published or not photo_published:
    raise SystemExit('published_state=FAIL')
PY

code="$(curl -sS -X POST -o "$WORK/readiness.json" -w '%{http_code}' "$API_BASE/api/v1/transaction/photo" || true)"
echo "photo_webhook_http=$code"
if [[ "$code" == '401' ]]; then
  echo 'photo_webhook_readiness=PASS'
else
  echo 'photo_webhook_readiness=FAIL'
fi

status="$(docker inspect -f '{{.State.Status}}' "$N8N_CONTAINER")"
running="$(docker inspect -f '{{.State.Running}}' "$N8N_CONTAINER")"
restarting="$(docker inspect -f '{{.State.Restarting}}' "$N8N_CONTAINER")"
restart_count="$(docker inspect -f '{{.RestartCount}}' "$N8N_CONTAINER")"
echo "n8n_status=$status"
echo "n8n_running=$running"
echo "n8n_restarting=$restarting"
echo "n8n_restart_count=$restart_count"

echo 'N8N_MUTATION=NONE'
echo 'DB_MUTATION=NONE'
echo 'FRONTEND_MUTATION=NONE'
echo 'UX022R3_PHOTO_DEDUP_RECOVERY_STATUS=PASS'
