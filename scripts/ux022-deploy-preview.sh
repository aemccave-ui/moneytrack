#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

: "${DATABASE_URL:?DATABASE_URL is required}"
: "${MONEYTRACK_SMOKE_INIT_DATA:?MONEYTRACK_SMOKE_INIT_DATA is required for real webhook smoke}"

N8N_CONTAINER="${N8N_CONTAINER:-n8n}"
PREVIEW_ROOT="${PREVIEW_ROOT:-/var/www/moneytrack-miniapp-preview}"
PREVIEW_URL="${PREVIEW_URL:-https://preview.moneytrackapp.xyz}"
API_BASE="${API_BASE:-https://n8n.moneytrackapp.xyz/webhook}"
BACKUP_BASE="${BACKUP_BASE:-/var/backups/moneytrack/ux022}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="$BACKUP_BASE/$STAMP"
CANDIDATE_DIR="$(mktemp -d)"
MIGRATION_FILE="$(mktemp)"
RUNTIME_MUTATED=0
PREVIEW_MUTATED=0

# This script is intentionally incapable of production-frontend delivery.
[[ "$PREVIEW_ROOT" == "/var/www/moneytrack-miniapp-preview" ]] || {
  echo "preview_target_guard=FAIL root=$PREVIEW_ROOT" >&2
  exit 1
}
[[ "$PREVIEW_URL" == "https://preview.moneytrackapp.xyz" ]] || {
  echo "preview_target_guard=FAIL url=$PREVIEW_URL" >&2
  exit 1
}

for command_name in docker psql pg_dump curl rsync tar sha256sum python3 npm; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "runtime_preflight=FAIL missing_command=$command_name" >&2
    exit 1
  }
done

docker inspect "$N8N_CONTAINER" >/dev/null 2>&1 || {
  echo "runtime_preflight=FAIL n8n_container=$N8N_CONTAINER" >&2
  exit 1
}

# n8n import deactivates imported workflows by default. UX-022 therefore requires
# a CLI generation that can export the actually published runtime version and can
# publish the imported draft again before the controlled restart.
if ! docker exec "$N8N_CONTAINER" n8n export:workflow --help 2>&1 | grep -Fq -- '--published'; then
  echo 'runtime_preflight=FAIL n8n_export_published_unsupported' >&2
  exit 1
fi
if ! docker exec "$N8N_CONTAINER" n8n publish:workflow --help >/dev/null 2>&1; then
  echo 'runtime_preflight=FAIL n8n_publish_workflow_unsupported' >&2
  exit 1
fi

echo '# Phase'
echo 'UX-022 preview delivery'
echo '# Gate'
echo 'source -> migration -> backup -> api -> smoke -> preview'
echo 'preview_target_guard=PASS'
echo 'runtime_preflight=PASS'

cleanup_tmp() {
  rm -rf "$CANDIDATE_DIR" "$MIGRATION_FILE"
}

export_workflow() {
  local id="$1"
  local published_name="$2"
  local draft_name="${published_name%.json}.draft.json"

  docker exec "$N8N_CONTAINER" rm -f "/tmp/$published_name" "/tmp/$draft_name"

  # Runtime rollback must restore what is actually published, not a potentially
  # different unpublished draft. Preserve the draft separately as recovery evidence.
  docker exec "$N8N_CONTAINER" n8n export:workflow \
    --id="$id" --published --output="/tmp/$published_name"
  docker exec "$N8N_CONTAINER" n8n export:workflow \
    --id="$id" --output="/tmp/$draft_name"

  docker cp "$N8N_CONTAINER:/tmp/$published_name" "$BACKUP_DIR/$published_name" >/dev/null
  docker cp "$N8N_CONTAINER:/tmp/$draft_name" "$BACKUP_DIR/$draft_name" >/dev/null
  test -s "$BACKUP_DIR/$published_name"
  test -s "$BACKUP_DIR/$draft_name"
}

import_publish() {
  local file="$1"
  local id="$2"
  local name="$(basename "$file")"
  docker cp "$file" "$N8N_CONTAINER:/tmp/$name" >/dev/null
  docker exec "$N8N_CONTAINER" n8n import:workflow --input="/tmp/$name"
  docker exec "$N8N_CONTAINER" n8n publish:workflow --id="$id"
}

restore_preview() {
  [[ -s "$BACKUP_DIR/preview.tgz" ]] || return 0
  mkdir -p "$PREVIEW_ROOT"
  find "$PREVIEW_ROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  tar -C "$PREVIEW_ROOT" -xzf "$BACKUP_DIR/preview.tgz"
}

rollback() {
  local exit_code=$?
  trap - ERR
  echo "rollback_triggered=YES exit_code=$exit_code" >&2
  if (( PREVIEW_MUTATED )); then
    restore_preview || echo 'rollback_preview=FAIL' >&2
  fi
  if (( RUNTIME_MUTATED )); then
    import_publish "$BACKUP_DIR/transactions.before.json" UX022TxApi202608 || echo 'rollback_transactions_workflow=FAIL' >&2
    import_publish "$BACKUP_DIR/summary.before.json" UX022Summary202608 || echo 'rollback_summary_workflow=FAIL' >&2
    import_publish "$BACKUP_DIR/presets.before.json" UX022Presets202608 || echo 'rollback_presets_workflow=FAIL' >&2
    docker restart "$N8N_CONTAINER" >/dev/null || echo 'rollback_n8n_restart=FAIL' >&2
    psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$ROOT/db/domain/UX-022/990_rollback_code.sql" || echo 'rollback_db_code=FAIL' >&2
  fi
  echo "rollback_point=$BACKUP_DIR" >&2
  cleanup_tmp
  exit "$exit_code"
}
trap rollback ERR
trap cleanup_tmp EXIT

# 1-4. Source/static/lint/build. No runtime mutation before these pass.
"$ROOT/scripts/ux022-source-gate.sh"

# Generate adapters before touching runtime.
python3 "$ROOT/scripts/ux022-generate-api-workflows.py" --out-dir "$CANDIDATE_DIR"
python3 "$ROOT/scripts/ux022-merge-lifecycle-into-presets.py" \
  --presets "$CANDIDATE_DIR/ux022-presets.candidate.json" \
  --lifecycle "$CANDIDATE_DIR/ux022-lifecycle.candidate.json" \
  --output "$CANDIDATE_DIR/ux022-presets-lifecycle.candidate.json"

# 5. Migration validation is rollback-only against the real schema.
"$ROOT/scripts/ux022-migration-gate.sh"

# 6. Runtime backup / rollback point. Each n8n workflow gets both its published
# runtime version (used by automatic rollback) and its current draft (preserved for
# manual recovery/audit if it differed from the published runtime).
mkdir -p "$BACKUP_DIR"
pg_dump "$DATABASE_URL" --schema=moneytrack --format=custom --file="$BACKUP_DIR/moneytrack.before.dump"
test -s "$BACKUP_DIR/moneytrack.before.dump"
export_workflow UX022TxApi202608 transactions.before.json
export_workflow UX022Summary202608 summary.before.json
export_workflow UX022Presets202608 presets.before.json
mkdir -p "$PREVIEW_ROOT"
tar -C "$PREVIEW_ROOT" -czf "$BACKUP_DIR/preview.tgz" .
test -s "$BACKUP_DIR/preview.tgz"
printf '%s\n' "$STAMP" > "$BACKUP_DIR/rollback-point.txt"
echo "runtime_backup=PASS path=$BACKUP_DIR"

# Prepare the persistent migration from the exact same rendered body that the
# rollback-only migration gate validated. This prevents validate/apply drift.
{
  echo 'begin;'
  "$ROOT/scripts/ux022-render-migration.sh"
  echo 'commit;'
} > "$MIGRATION_FILE"

RUNTIME_MUTATED=1
psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$MIGRATION_FILE"
echo 'db_migration_apply=PASS'

# 7. Replace only the three known UX workflows. Lifecycle routes are merged into
# the existing preset workflow ID so rollback can restore the exact prior surface.
import_publish "$CANDIDATE_DIR/ux022-transactions.candidate.json" UX022TxApi202608
import_publish "$CANDIDATE_DIR/ux022-summary.candidate.json" UX022Summary202608
import_publish "$CANDIDATE_DIR/ux022-presets-lifecycle.candidate.json" UX022Presets202608
docker restart "$N8N_CONTAINER" >/dev/null

# 8. Real webhook registration readiness: missing auth must reach the webhook and
# return 401, never nginx/n8n 404. Retry only this short readiness segment.
readiness_paths=(
  'api/v1/transactions'
  'api/v1/accounts-explorer-summary'
  'api/v1/filter-presets'
  'api/v1/accounts/archived'
)
for path in "${readiness_paths[@]}"; do
  ready=0
  for _ in $(seq 1 20); do
    code="$(curl -sS -o /tmp/ux022-readiness.json -w '%{http_code}' "$API_BASE/$path" || true)"
    if [[ "$code" == '401' ]]; then ready=1; break; fi
    sleep 1
  done
  if (( ! ready )); then
    echo "real_webhook_readiness=FAIL path=$path http=$code" >&2
    exit 1
  fi
  echo "real_webhook_readiness=PASS path=$path"
done

# 9. Authenticated runtime contract + reversible lifecycle smoke.
python3 "$ROOT/scripts/ux022-runtime-smoke.py" --base "$API_BASE" --init-data "$MONEYTRACK_SMOKE_INIT_DATA"

# 10. Preview frontend only.
PREVIEW_MUTATED=1
rsync -a --delete "$ROOT/miniapp/dist/" "$PREVIEW_ROOT/"
echo "preview_frontend_deploy=PASS root=$PREVIEW_ROOT"

# 11. Preview artifact identity: compare the actual Vite asset and its bytes.
local_asset="$(grep -oE '/assets/[^"'"' ]+\.js' "$ROOT/miniapp/dist/index.html" | head -n1)"
preview_html="$(curl -fsS "$PREVIEW_URL/")"
remote_asset="$(printf '%s' "$preview_html" | grep -oE '/assets/[^"'"' ]+\.js' | head -n1)"
[[ -n "$local_asset" && -n "$remote_asset" && "$local_asset" == "$remote_asset" ]]
local_sha="$(sha256sum "$ROOT/miniapp/dist$local_asset" | awk '{print $1}')"
remote_tmp="$(mktemp)"
curl -fsS "$PREVIEW_URL$remote_asset" -o "$remote_tmp"
remote_sha="$(sha256sum "$remote_tmp" | awk '{print $1}')"
rm -f "$remote_tmp"
[[ -n "$local_sha" && "$local_sha" == "$remote_sha" ]]
echo "preview_artifact=$remote_asset"
echo "preview_artifact_sha256=$remote_sha"
echo 'preview_artifact_identity=PASS'

# Viewport/visual acceptance is intentionally not fabricated by this shell.
echo 'viewport_gate=PENDING_VISUAL_ACCEPTANCE widths=320,360,390'
echo "rollback_point=$BACKUP_DIR"
echo 'preview_delivery_gate=PASS'

# Success: keep the rollback artifacts; disable failure rollback.
trap - ERR
