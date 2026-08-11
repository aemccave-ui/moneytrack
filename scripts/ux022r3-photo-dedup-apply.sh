#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

N8N_CONTAINER="${MONEYTRACK_N8N_CONTAINER:-n8n}"
API_BASE="${MONEYTRACK_API_BASE:-https://n8n.moneytrackapp.xyz/webhook}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="${MONEYTRACK_PHOTO_DEDUP_BACKUP_DIR:-/var/backups/moneytrack/ux022r3-photo-dedup/$STAMP}"
WORK="$(mktemp -d /tmp/ux022r3-photo-dedup-apply.XXXXXX)"
QUICK_ID="UX022QuickInput202608"
PHOTO_ID="5VC0EcFB21rwTfoI"
MUTATED=0
SUCCESS=0

cleanup() {
  rm -rf "$WORK"
}

container_tmp_rm() {
  local remote="$1"
  # docker cp may create root-owned files under sticky /tmp. Cleanup must never
  # turn a successful n8n import/publish (or rollback) into a failed mutation.
  docker exec -u 0 "$N8N_CONTAINER" rm -f "$remote" >/dev/null 2>&1 || true
}

for command_name in docker curl python3; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "runtime_preflight=FAIL missing_command=$command_name" >&2
    exit 1
  }
done

docker inspect "$N8N_CONTAINER" >/dev/null

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo 'clean_checkout=FAIL' >&2
  git status --short >&2
  exit 1
fi

echo '# Phase'
echo 'UX-022R3 MiniApp photo duplicate runtime apply'
echo '# Gate'
echo 'CONTROLLED_N8N_MUTATION_ONLY'
echo "HEAD=$(git rev-parse HEAD)"
echo 'clean_checkout=PASS'

bash "$ROOT/scripts/ux022r3-photo-dedup-gate.sh"
echo 'photo_dedup_preflight=PASS'

export_one() {
  local id="$1"
  local target="$2"
  local remote="/tmp/ux022r3-export-$$-$(basename "$target")"
  container_tmp_rm "$remote"
  docker exec "$N8N_CONTAINER" n8n export:workflow --id="$id" --output="$remote" >/dev/null
  docker cp "$N8N_CONTAINER:$remote" "$target" >/dev/null
  container_tmp_rm "$remote"
}

export_one "$QUICK_ID" "$WORK/quick.before.json"
export_one "$PHOTO_ID" "$WORK/photo.before.json"

python3 - "$WORK/quick.before.json" "$WORK/photo.before.json" <<'PY'
import json,sys
from pathlib import Path

def one(path):
    raw=json.loads(Path(path).read_text(encoding='utf-8'))
    return raw[0] if isinstance(raw,list) else raw

def node(wf,name):
    rows=[n for n in wf.get('nodes',[]) if n.get('name')==name]
    return rows[0] if len(rows)==1 else None

quick=one(sys.argv[1]); photo=one(sys.argv[2])
assert str(quick.get('id'))=='UX022QuickInput202608'
assert str(photo.get('id'))=='5VC0EcFB21rwTfoI'
assert quick.get('active') is True
assert photo.get('active') is True
assert quick.get('versionId')==quick.get('activeVersionId'), 'quick_unpublished_drift'
assert photo.get('versionId')==photo.get('activeVersionId'), 'photo_unpublished_drift'
assert node(quick,'Photo Hash') is None, 'photo_dedup_already_applied_quick'
fmt=node(quick,'Photo Format')
assert fmt and 'RECEIPT_DUPLICATE_EXACT' not in (fmt.get('parameters',{}).get('jsCode') or ''), 'photo_format_already_patched'
semantic=node(photo,'Check semantic duplicate receipt')
assert semantic, 'semantic_node_missing'
query=(semantic.get('parameters',{}).get('query') or '').lower()
assert 'amount_signature' not in query, 'photo_dedup_already_applied_photo'
print('runtime_before_state=EXPECTED_UNPATCHED')
PY

python3 "$ROOT/scripts/ux022r3-patch-photo-dedup.py" \
  --quick-before "$WORK/quick.before.json" \
  --photo-before "$WORK/photo.before.json" \
  --quick-after "$WORK/quick.after.json" \
  --photo-after "$WORK/photo.after.json"

mkdir -p "$BACKUP_DIR"
printf '%s\n' "$(git rev-parse HEAD)" > "$BACKUP_DIR/source-head.txt"
cp "$WORK/quick.before.json" "$BACKUP_DIR/quick.before.json"
cp "$WORK/photo.before.json" "$BACKUP_DIR/photo.before.json"
echo "runtime_backup=PASS path=$BACKUP_DIR"

import_publish() {
  local file="$1"
  local id="$2"
  local remote="/tmp/ux022r3-import-$$-${id}.json"
  container_tmp_rm "$remote"
  docker cp "$file" "$N8N_CONTAINER:$remote" >/dev/null
  docker exec "$N8N_CONTAINER" n8n import:workflow --input="$remote"
  docker exec "$N8N_CONTAINER" n8n publish:workflow --id="$id"
  container_tmp_rm "$remote"
}

rollback() {
  local status="${1:-1}"
  trap - ERR EXIT
  echo "UX022R3_PHOTO_DEDUP_APPLY=FAIL status=$status" >&2
  if (( MUTATED )); then
    import_publish "$BACKUP_DIR/quick.before.json" "$QUICK_ID" \
      && echo 'rollback_quick=PASS' >&2 \
      || echo 'rollback_quick=FAIL' >&2
    import_publish "$BACKUP_DIR/photo.before.json" "$PHOTO_ID" \
      && echo 'rollback_photo=PASS' >&2 \
      || echo 'rollback_photo=FAIL' >&2
    docker restart "$N8N_CONTAINER" >/dev/null \
      && echo 'rollback_n8n_restart=PASS' >&2 \
      || echo 'rollback_n8n_restart=FAIL' >&2
    echo 'rollback_n8n_workflows=ATTEMPTED' >&2
  fi
  echo "rollback_point=$BACKUP_DIR" >&2
  cleanup
  exit "$status"
}

on_exit() {
  local status=$?
  if (( status != 0 && SUCCESS == 0 && MUTATED )); then
    rollback "$status"
  fi
  cleanup
}
trap 'rollback $?' ERR
trap on_exit EXIT

MUTATED=1
import_publish "$WORK/quick.after.json" "$QUICK_ID"
import_publish "$WORK/photo.after.json" "$PHOTO_ID"
docker restart "$N8N_CONTAINER" >/dev/null
echo 'n8n_photo_dedup_publish=PASS'

ready=0
code=''
for _ in $(seq 1 30); do
  code="$(curl -sS -X POST -o "$WORK/readiness.json" -w '%{http_code}' "$API_BASE/api/v1/transaction/photo" || true)"
  if [[ "$code" == '401' ]]; then ready=1; break; fi
  sleep 1
done
if (( ! ready )); then
  echo "photo_webhook_readiness=FAIL http=$code" >&2
  false
fi
echo 'photo_webhook_readiness=PASS http=401'

export_one "$QUICK_ID" "$WORK/quick.after.runtime.json"
export_one "$PHOTO_ID" "$WORK/photo.after.runtime.json"

python3 - "$WORK/quick.after.runtime.json" "$WORK/photo.after.runtime.json" <<'PY'
import json,sys
from pathlib import Path

def one(path):
    raw=json.loads(Path(path).read_text(encoding='utf-8'))
    return raw[0] if isinstance(raw,list) else raw

def node(wf,name):
    rows=[n for n in wf.get('nodes',[]) if n.get('name')==name]
    assert len(rows)==1,(name,len(rows))
    return rows[0]

quick=one(sys.argv[1]); photo=one(sys.argv[2])
assert quick.get('active') is True and quick.get('versionId')==quick.get('activeVersionId')
assert photo.get('active') is True and photo.get('versionId')==photo.get('activeVersionId')
h=node(quick,'Photo Hash')['parameters']['jsCode']
assert "createHash('sha256')" in h and 'miniapp-sha256:' in h
prep=node(quick,'Photo Prepare')['parameters']['jsCode']
assert "telegram_file_id: $('Photo Hash').first().json.photo_identity" in prep
fmt=node(quick,'Photo Format')['parameters']['jsCode']
assert 'RECEIPT_DUPLICATE_EXACT' in fmt and 'RECEIPT_DUPLICATE_SEMANTIC' in fmt and 'http_status: 409' in fmt
exact=node(photo,'Check duplicate receipt')['parameters']['query'].lower()
assert 'r.user_id =' in exact and 'r.telegram_file_id' in exact
semantic=node(photo,'Check semantic duplicate receipt')['parameters']['query'].lower()
for token in ('receipt_items','item_count','amount_signature','receipt_date','total_amount','upper(r.currency)'):
    assert token in semantic,token
print('published_runtime_contract=PASS')
PY

SUCCESS=1
MUTATED=0
trap - ERR

echo "rollback_point=$BACKUP_DIR"
echo 'DB_MUTATION=NONE'
echo 'FRONTEND_MUTATION=NONE'
echo 'N8N_MUTATION=UX022QuickInput202608,5VC0EcFB21rwTfoI_PUBLISHED'
echo 'TELEGRAM_RUNTIME_DUPLICATE_ACCEPTANCE=PENDING'
echo 'UX022R3_PHOTO_DEDUP_APPLY=PASS'
