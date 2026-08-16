#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APPLY=0
EXPECTED_HEAD=""
INVITE_RUNTIME_DIR=""
OUTPUT_DIR=""
MT_DB_CONTAINER="${MT_DB_CONTAINER:-moneytrack-db}"
SQL="$ROOT/db/domain/SPC-001/123_space_member_identity_read.sql"
VERIFY_SQL="$ROOT/db/domain/SPC-001/315_verify_live_post_migration_readonly.sql"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --expected-head) EXPECTED_HEAD="${2:-}"; shift 2 ;;
    --invite-runtime-dir) INVITE_RUNTIME_DIR="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    *) echo "ERROR: unexpected argument: $1" >&2; exit 2 ;;
  esac
done

[[ "$APPLY" -eq 1 ]] || { echo 'SPC001_F4_MEMBER_READ=REFUSED explicit_--apply_required' >&2; exit 2; }
[[ -n "$EXPECTED_HEAD" && -n "$INVITE_RUNTIME_DIR" && -n "$OUTPUT_DIR" ]] || exit 2
[[ "$INVITE_RUNTIME_DIR" = /* && "$OUTPUT_DIR" = /* ]] || { echo 'ERROR: absolute paths required' >&2; exit 2; }
case "$OUTPUT_DIR" in /tmp|/tmp/*) echo 'ERROR: durable output required' >&2; exit 2;; esac
[[ ! -e "$OUTPUT_DIR" ]] || { echo "ERROR: output exists: $OUTPUT_DIR" >&2; exit 2; }

HEAD_SHA="$(git rev-parse HEAD)"
[[ "$HEAD_SHA" == "$EXPECTED_HEAD" ]] || { echo "ERROR: head mismatch expected=$EXPECTED_HEAD actual=$HEAD_SHA" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo 'ERROR: dirty checkout' >&2; exit 1; }

for f in "$INVITE_RUNTIME_DIR/metadata.txt" "$INVITE_RUNTIME_DIR/source-head.txt" "$INVITE_RUNTIME_DIR/SHA256SUMS"; do
  [[ -s "$f" ]] || { echo "ERROR: invite runtime evidence missing $f" >&2; exit 1; }
done
(
  cd "$INVITE_RUNTIME_DIR"
  sha256sum -c SHA256SUMS >/dev/null
)
grep -Fx 'SPC001_INVITE_RUNTIME_CONFIG=PASS' "$INVITE_RUNTIME_DIR/metadata.txt" >/dev/null
grep -Fx 'DB_MUTATION=NONE' "$INVITE_RUNTIME_DIR/metadata.txt" >/dev/null
grep -Fx 'WORKFLOW_STATE_UNCHANGED=PASS' "$INVITE_RUNTIME_DIR/metadata.txt" >/dev/null

BASE_HEAD="$(cat "$INVITE_RUNTIME_DIR/source-head.txt")"
[[ "$BASE_HEAD" =~ ^[0-9a-f]{40}$ ]]
git merge-base --is-ancestor "$BASE_HEAD" "$HEAD_SHA"

mapfile -t CHANGED < <(git diff --name-only "$BASE_HEAD..$HEAD_SHA")
for path in "${CHANGED[@]}"; do
  case "$path" in
    miniapp/src/SpaceGate.jsx|miniapp/src/spc001-space.css|miniapp/src/api-errors.js|db/domain/SPC-001/123_space_member_identity_read.sql|scripts/spc001-preview-source-gate.py|scripts/spc001-f4-member-read-apply.sh|scripts/spc001-f4-preview-apply.sh) ;;
    *) echo "ERROR: non-F4 source changed after accepted invite runtime: $path" >&2; exit 1 ;;
  esac
done
echo "INVITE_RUNTIME_TO_F4_SAFE_DELTA=PASS files=${#CHANGED[@]}"
echo 'INVITE_RUNTIME_ACCEPTANCE_EVIDENCE=PASS'

python3 "$ROOT/scripts/spc001-preview-source-gate.py"

[[ "$(docker inspect -f '{{.State.Running}}' "$MT_DB_CONTAINER")" == true ]] || { echo 'ERROR: moneytrack-db not running' >&2; exit 1; }
[[ -s "$SQL" && -s "$VERIFY_SQL" ]]

umask 077
mkdir -p "$OUTPUT_DIR"
chmod 700 "$OUTPUT_DIR"
printf '%s\n' "$HEAD_SHA" > "$OUTPUT_DIR/source-head.txt"
printf '%s\n' "$BASE_HEAD" > "$OUTPUT_DIR/invite-runtime-head.txt"
sha256sum "$INVITE_RUNTIME_DIR/SHA256SUMS" > "$OUTPUT_DIR/invite-runtime-manifest.sha256"

run315() {
  docker exec -i "$MT_DB_CONTAINER" \
    psql -X -q -v ON_ERROR_STOP=1 -U moneytrack -d moneytrack < "$VERIFY_SQL"
}

run315 > "$OUTPUT_DIR/live315.before.txt"
grep -Fx 'SPC001_LIVE_POST_MIGRATION_VERIFY=PASS' "$OUTPUT_DIR/live315.before.txt" >/dev/null
echo 'LIVE_315_BEFORE_F4=PASS'

{
  echo 'begin;'
  docker exec "$MT_DB_CONTAINER" \
    psql -X -q -At -v ON_ERROR_STOP=1 -U moneytrack -d moneytrack \
    -c "select pg_get_functiondef('moneytrack.space_members_api_read_v1(bigint,bigint)'::regprocedure);"
  echo ';'
  echo 'commit;'
} > "$OUTPUT_DIR/space-members-api.before.sql"
[[ -s "$OUTPUT_DIR/space-members-api.before.sql" ]]
echo 'FUNCTION_BACKUP=PASS'

MUTATED=0
rollback() {
  local rc=$?
  trap - ERR
  echo "ROLLBACK_TRIGGERED=YES rc=$rc" >&2
  if [[ "$MUTATED" -eq 1 ]]; then
    if docker exec -i "$MT_DB_CONTAINER" \
      psql -X -q -v ON_ERROR_STOP=1 -U moneytrack -d moneytrack \
      < "$OUTPUT_DIR/space-members-api.before.sql"; then
      echo 'F4_MEMBER_READ_ROLLBACK=PASS' >&2
    else
      echo 'F4_MEMBER_READ_ROLLBACK=FAIL' >&2
    fi
  fi
  echo "SPC001_F4_MEMBER_READ=FAIL rc=$rc" >&2
  exit "$rc"
}
trap rollback ERR

MUTATED=1
docker exec -i "$MT_DB_CONTAINER" \
  psql -X -q -v ON_ERROR_STOP=1 -U moneytrack -d moneytrack < "$SQL"
echo 'F4_MEMBER_READ_APPLY=PASS'

docker exec "$MT_DB_CONTAINER" \
  psql -X -q -At -v ON_ERROR_STOP=1 -U moneytrack -d moneytrack \
  -c "select case when pg_get_functiondef('moneytrack.space_members_api_read_v1(bigint,bigint)'::regprocedure) like '%first_name%' and pg_get_functiondef('moneytrack.space_members_api_read_v1(bigint,bigint)'::regprocedure) like '%username%' and pg_get_functiondef('moneytrack.space_members_api_read_v1(bigint,bigint)'::regprocedure) not like '%telegram_user_id%' then 'MEMBER_IDENTITY_WRAPPER=PASS' else 'MEMBER_IDENTITY_WRAPPER=FAIL' end;" \
  | tee "$OUTPUT_DIR/function-verify.txt"
grep -Fx 'MEMBER_IDENTITY_WRAPPER=PASS' "$OUTPUT_DIR/function-verify.txt" >/dev/null

run315 > "$OUTPUT_DIR/live315.after.txt"
grep -Fx 'SPC001_LIVE_POST_MIGRATION_VERIFY=PASS' "$OUTPUT_DIR/live315.after.txt" >/dev/null
cmp -s "$OUTPUT_DIR/live315.before.txt" "$OUTPUT_DIR/live315.after.txt"
echo 'LIVE_315_AFTER_F4=PASS'
echo 'LIVE_315_UNCHANGED=PASS'

{
  echo "HEAD=$HEAD_SHA"
  echo "INVITE_RUNTIME_HEAD=$BASE_HEAD"
  echo "INVITE_RUNTIME_EVIDENCE_DIR=$INVITE_RUNTIME_DIR"
  echo 'FUNCTION_BACKUP=PASS'
  echo 'F4_MEMBER_READ_APPLY=PASS'
  echo 'MEMBER_IDENTITY_WRAPPER=PASS'
  echo 'LIVE_315_BEFORE_F4=PASS'
  echo 'LIVE_315_AFTER_F4=PASS'
  echo 'LIVE_315_UNCHANGED=PASS'
  echo 'DB_MUTATION=READ_MODEL_FUNCTION_APPLIED'
  echo 'FINANCIAL_DATA_MUTATION=NONE'
  echo 'N8N_MUTATION=NONE'
  echo 'PREVIEW_MUTATION=NONE'
  echo 'PRODUCTION_FRONTEND_MUTATION=NONE'
  echo 'SPC001_F4_MEMBER_READ=PASS'
} > "$OUTPUT_DIR/metadata.txt"

python3 - "$OUTPUT_DIR" <<'PY'
from pathlib import Path
import hashlib,sys
root=Path(sys.argv[1]); manifest=root/'SHA256SUMS'; rows=[]
for p in sorted(root.rglob('*')):
    if p.is_file() and p != manifest:
        rows.append(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(root)}\n")
manifest.write_text(''.join(rows),encoding='utf-8')
PY
sync

MUTATED=0
trap - ERR

echo "SPC001_F4_MEMBER_READ_EVIDENCE_DIR=$OUTPUT_DIR"
echo 'DB_MUTATION=READ_MODEL_FUNCTION_APPLIED'
echo 'FINANCIAL_DATA_MUTATION=NONE'
echo 'N8N_MUTATION=NONE'
echo 'PREVIEW_MUTATION=NONE'
echo 'PRODUCTION_FRONTEND_MUTATION=NONE'
echo 'ROLLBACK_TRIGGERED=NO'
echo 'SPC001_F4_MEMBER_READ=PASS'
