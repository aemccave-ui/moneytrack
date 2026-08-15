#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APPLY=0
EXPECTED_HEAD=""
F3_DIR=""
OUTPUT_DIR=""
INVITE_TTL_SECONDS=86400

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --expected-head) EXPECTED_HEAD="${2:-}"; shift 2 ;;
    --f3-dir) F3_DIR="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    *) echo "ERROR: unexpected argument: $1" >&2; exit 2 ;;
  esac
done

[[ "$APPLY" -eq 1 ]] || { echo 'SPC001_INVITE_RUNTIME_CONFIG=REFUSED explicit_--apply_required' >&2; exit 2; }
[[ -n "$EXPECTED_HEAD" && -n "$F3_DIR" && -n "$OUTPUT_DIR" ]] || {
  echo 'SPC001_INVITE_RUNTIME_CONFIG=REFUSED expected_head_f3_output_required' >&2
  exit 2
}
[[ "$F3_DIR" = /* && "$OUTPUT_DIR" = /* ]] || { echo 'ERROR: absolute paths required' >&2; exit 2; }
case "$OUTPUT_DIR" in /tmp|/tmp/*) echo 'ERROR: durable output required' >&2; exit 2;; esac
[[ ! -e "$OUTPUT_DIR" ]] || { echo "ERROR: output exists: $OUTPUT_DIR" >&2; exit 2; }

HEAD_SHA="$(git rev-parse HEAD)"
[[ "$HEAD_SHA" == "$EXPECTED_HEAD" ]] || { echo "ERROR: head mismatch expected=$EXPECTED_HEAD actual=$HEAD_SHA" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo 'ERROR: dirty checkout' >&2; exit 1; }

for f in "$F3_DIR/preview-metadata.txt" "$F3_DIR/source-head.txt" "$F3_DIR/SHA256SUMS"; do
  [[ -s "$f" ]] || { echo "ERROR: F3 evidence missing $f" >&2; exit 1; }
done
(
  cd "$F3_DIR"
  sha256sum -c SHA256SUMS >/dev/null
)
grep -Fx 'SPC001_SHARED_PREVIEW=PASS' "$F3_DIR/preview-metadata.txt" >/dev/null
grep -Fx 'DB_MUTATION=NONE' "$F3_DIR/preview-metadata.txt" >/dev/null
grep -Fx 'N8N_MUTATION=NONE' "$F3_DIR/preview-metadata.txt" >/dev/null
grep -Fx 'PRODUCTION_FRONTEND_MUTATION=NONE' "$F3_DIR/preview-metadata.txt" >/dev/null

F3_HEAD="$(cat "$F3_DIR/source-head.txt")"
[[ "$F3_HEAD" =~ ^[0-9a-f]{40}$ ]] || { echo 'ERROR: invalid F3 head' >&2; exit 1; }
git merge-base --is-ancestor "$F3_HEAD" "$HEAD_SHA" || { echo 'ERROR: F3 head is not ancestor' >&2; exit 1; }

mapfile -t CHANGED < <(git diff --name-only "$F3_HEAD..$HEAD_SHA")
for path in "${CHANGED[@]}"; do
  case "$path" in
    ops/spc001/docker-compose.spc001.yml|scripts/spc001-invite-runtime-apply.sh|scripts/spc001-invite-runtime-source-gate.py|.github/workflows/spc001-source-contract.yml) ;;
    *) echo "ERROR: non-invite-runtime source changed after accepted F3: $path" >&2; exit 1 ;;
  esac
done
echo "F3_TO_INVITE_RUNTIME_SAFE_DELTA=PASS files=${#CHANGED[@]}"
echo 'F3_ACCEPTANCE_EVIDENCE=PASS'

python3 "$ROOT/scripts/spc001-invite-runtime-source-gate.py"

STACK=/root/stack/n8n
BASE_COMPOSE="$STACK/docker-compose.yml"
HARDENING_COMPOSE="$STACK/docker-compose.prod-h.yml"
SEC_OVERLAY="$STACK/docker-compose.sec001.yml"
INTERPOLATION="$STACK/compose-interpolation.prod-h.sh"
OVERLAY_SOURCE="$ROOT/ops/spc001/docker-compose.spc001.yml"
OVERLAY_TARGET="$STACK/docker-compose.spc001.yml"
N8N_CONTAINER="${N8N_CONTAINER:-n8n}"
N8N_DB_CONTAINER="${N8N_DB_CONTAINER:-postgres}"

for f in "$BASE_COMPOSE" "$HARDENING_COMPOSE" "$SEC_OVERLAY" "$INTERPOLATION" "$OVERLAY_SOURCE"; do
  [[ -s "$f" ]] || { echo "ERROR: required runtime file missing $f" >&2; exit 1; }
done
for c in "$N8N_CONTAINER" "$N8N_DB_CONTAINER"; do
  [[ "$(docker inspect -f '{{.State.Running}}' "$c")" == true ]] || { echo "ERROR: container not running $c" >&2; exit 1; }
done

SERVICE="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$N8N_CONTAINER")"
[[ -n "$SERVICE" ]] || { echo 'ERROR: compose service label missing' >&2; exit 1; }

umask 077
mkdir -p "$OUTPUT_DIR"
chmod 700 "$OUTPUT_DIR"
printf '%s\n' "$HEAD_SHA" > "$OUTPUT_DIR/source-head.txt"
printf '%s\n' "$F3_HEAD" > "$OUTPUT_DIR/f3-head.txt"
sha256sum "$F3_DIR/SHA256SUMS" > "$OUTPUT_DIR/f3-manifest.sha256"

snapshot_workflows() {
  docker exec -i "$N8N_DB_CONTAINER" \
    psql -X -q -At -v ON_ERROR_STOP=1 -U n8n -d n8n <<'SQL'
select (j->>'id') || E'\t' || coalesce(j->>'activeVersionId','') || E'\t' || coalesce(j->>'active','')
from (select to_jsonb(x) j from workflow_entity x) q
order by j->>'id';
SQL
}

snapshot_workflows > "$OUTPUT_DIR/workflows.before.tsv"
[[ -s "$OUTPUT_DIR/workflows.before.tsv" ]]
echo 'N8N_METADATA_READONLY=PASS phase=before'

BOT_TOKEN="$(
  docker inspect "$N8N_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' |
    awk -F= '$1=="MONEYTRACK_BOT_TOKEN" {print substr($0,index($0,"=")+1); exit}'
)"
[[ -n "$BOT_TOKEN" ]] || { echo 'ERROR: running bot token missing' >&2; exit 1; }

BOT_META="$OUTPUT_DIR/telegram-getme.json"
curl -fsS "https://api.telegram.org/bot${BOT_TOKEN}/getMe" -o "$BOT_META"
unset BOT_TOKEN

read -r BOT_USERNAME HAS_MAIN_WEB_APP < <(
  python3 - "$BOT_META" <<'PY'
import json,sys
p=json.load(open(sys.argv[1],encoding='utf-8'))
if p.get('ok') is not True: raise SystemExit('Telegram getMe failed')
r=p.get('result') or {}
username=str(r.get('username') or '').strip()
if not username: raise SystemExit('Telegram bot username missing')
print(username, 'YES' if r.get('has_main_web_app') is True else 'NO')
PY
)
[[ "$HAS_MAIN_WEB_APP" == YES ]] || { echo 'SPC001_INVITE_RUNTIME_CONFIG=REFUSED_MAIN_MINI_APP_NOT_ENABLED' >&2; exit 1; }
INVITE_BASE_URL="https://t.me/${BOT_USERNAME}"
[[ "$INVITE_BASE_URL" =~ ^https://t\.me/[A-Za-z0-9_]+$ ]]

echo "BOT_USERNAME=$BOT_USERNAME"
echo "HAS_MAIN_WEB_APP=$HAS_MAIN_WEB_APP"
echo "INVITE_BASE_URL=$INVITE_BASE_URL"
echo "INVITE_TTL_SECONDS=$INVITE_TTL_SECONDS"

cp -a "$INTERPOLATION" "$OUTPUT_DIR/compose-interpolation.before"
chmod 600 "$OUTPUT_DIR/compose-interpolation.before"
OVERLAY_EXISTED=0
if [[ -f "$OVERLAY_TARGET" ]]; then
  OVERLAY_EXISTED=1
  cp -a "$OVERLAY_TARGET" "$OUTPUT_DIR/docker-compose.spc001.before"
fi
echo 'CONFIG_BACKUP=PASS'

SOURCE_MUTATED=0
RECREATE_ATTEMPTED=0
TMP_RENDERED="$(mktemp)"
chmod 600 "$TMP_RENDERED"

compose_with_current_overlay() {
  local args=(-p n8n -f "$BASE_COMPOSE" -f "$HARDENING_COMPOSE" -f "$SEC_OVERLAY")
  [[ -f "$OVERLAY_TARGET" ]] && args+=(-f "$OVERLAY_TARGET")
  docker compose "${args[@]}" "$@"
}

wait_n8n() {
  local ready=0
  for _ in $(seq 1 60); do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$N8N_CONTAINER" 2>/dev/null || true)" == true ]] \
      && curl -fsS --max-time 5 http://127.0.0.1:5678/healthz >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 2
  done
  [[ "$ready" -eq 1 ]]
}

rollback() {
  local rc=$?
  trap - ERR
  rm -f "$TMP_RENDERED"
  echo "ROLLBACK_TRIGGERED=YES rc=$rc" >&2

  if [[ "$SOURCE_MUTATED" -eq 1 ]]; then
    cp -a "$OUTPUT_DIR/compose-interpolation.before" "$INTERPOLATION"
    chmod 600 "$INTERPOLATION"
    if [[ "$OVERLAY_EXISTED" -eq 1 ]]; then
      cp -a "$OUTPUT_DIR/docker-compose.spc001.before" "$OVERLAY_TARGET"
    else
      rm -f "$OVERLAY_TARGET"
    fi
    echo 'CONFIG_SOURCE_ROLLBACK=PASS' >&2
  fi

  if [[ "$RECREATE_ATTEMPTED" -eq 1 ]]; then
    if (
      set -a
      # shellcheck source=/dev/null
      source "$INTERPOLATION"
      set +a
      compose_with_current_overlay up -d --no-deps --force-recreate "$SERVICE" >/dev/null
    ) && wait_n8n; then
      echo 'N8N_CONFIG_ROLLBACK=PASS' >&2
    else
      echo 'N8N_CONFIG_ROLLBACK=FAIL' >&2
    fi
  fi

  echo "SPC001_INVITE_RUNTIME_CONFIG=FAIL rc=$rc" >&2
  exit "$rc"
}
trap rollback ERR

SOURCE_MUTATED=1
python3 - "$INTERPOLATION" "$INVITE_TTL_SECONDS" "$INVITE_BASE_URL" <<'PY'
from pathlib import Path
import re,shlex,sys
p=Path(sys.argv[1]); ttl=sys.argv[2]; base=sys.argv[3]
wanted={
    'MONEYTRACK_INVITE_TTL_SECONDS': ttl,
    'MONEYTRACK_INVITE_BASE_URL': base,
}
lines=p.read_text(encoding='utf-8').splitlines()
out=[]; seen=set()
for line in lines:
    replaced=False
    for key,value in wanted.items():
        if re.match(rf'^\s*(?:export\s+)?{re.escape(key)}=', line):
            out.append(f'export {key}={shlex.quote(value)}')
            seen.add(key); replaced=True; break
    if not replaced: out.append(line)
if any(k not in seen for k in wanted):
    out.extend(['', '# SPC-001 invite runtime configuration'])
    for key,value in wanted.items():
        if key not in seen:
            out.append(f'export {key}={shlex.quote(value)}')
p.write_text('\n'.join(out)+'\n',encoding='utf-8')
PY
chmod 600 "$INTERPOLATION"
install -m 0644 "$OVERLAY_SOURCE" "$OVERLAY_TARGET"
echo 'CONFIG_SOURCE_PATCH=PASS'

(
  set -a
  # shellcheck source=/dev/null
  source "$INTERPOLATION"
  set +a
  [[ "${#MONEYTRACK_PIN_PEPPER}" -ge 32 ]]
  [[ "$MONEYTRACK_INVITE_TTL_SECONDS" == "$INVITE_TTL_SECONDS" ]]
  [[ "$MONEYTRACK_INVITE_BASE_URL" == "$INVITE_BASE_URL" ]]
  compose_with_current_overlay config > "$TMP_RENDERED"
)

grep -Eq 'MONEYTRACK_PIN_PEPPER:[[:space:]]+.+$' "$TMP_RENDERED"
grep -Eq 'MONEYTRACK_INVITE_TTL_SECONDS:[[:space:]]+"?86400"?$' "$TMP_RENDERED"
grep -Fq "MONEYTRACK_INVITE_BASE_URL: $INVITE_BASE_URL" "$TMP_RENDERED" \
  || grep -Fq "MONEYTRACK_INVITE_BASE_URL: \"$INVITE_BASE_URL\"" "$TMP_RENDERED"
rm -f "$TMP_RENDERED"
echo 'COMPOSE_INVITE_CONFIG=PASS'

BEFORE_CONTAINER_ID="$(docker inspect --format '{{.Id}}' "$N8N_CONTAINER")"
RECREATE_ATTEMPTED=1
(
  set -a
  # shellcheck source=/dev/null
  source "$INTERPOLATION"
  set +a
  compose_with_current_overlay up -d --no-deps --force-recreate "$SERVICE" >/dev/null
)
wait_n8n
echo 'N8N_HEALTH=PASS'

AFTER_CONTAINER_ID="$(docker inspect --format '{{.Id}}' "$N8N_CONTAINER")"
[[ "$AFTER_CONTAINER_ID" != "$BEFORE_CONTAINER_ID" ]]

LIVE_ENV="$OUTPUT_DIR/invite-env.after.txt"
docker inspect "$N8N_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' |
  grep -E '^MONEYTRACK_INVITE_(TTL_SECONDS|BASE_URL)=' > "$LIVE_ENV"
grep -Fx "MONEYTRACK_INVITE_TTL_SECONDS=$INVITE_TTL_SECONDS" "$LIVE_ENV" >/dev/null
grep -Fx "MONEYTRACK_INVITE_BASE_URL=$INVITE_BASE_URL" "$LIVE_ENV" >/dev/null

PEPPER_STATE="$(
  docker inspect "$N8N_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' |
    awk -F= '$1=="MONEYTRACK_PIN_PEPPER" && length(substr($0,index($0,"=")+1))>=32 {found=1} END {print found?"SET":"UNSET"}'
)"
[[ "$PEPPER_STATE" == SET ]]
echo 'LIVE_INVITE_ENV=PASS'
echo 'SEC001_PIN_PEPPER_PRESERVED=PASS'

snapshot_workflows > "$OUTPUT_DIR/workflows.after.tsv"
cmp -s "$OUTPUT_DIR/workflows.before.tsv" "$OUTPUT_DIR/workflows.after.tsv"
echo 'N8N_METADATA_READONLY=PASS phase=after'
echo 'WORKFLOW_STATE_UNCHANGED=PASS'

cp -a "$INTERPOLATION" "$OUTPUT_DIR/compose-interpolation.after"
chmod 600 "$OUTPUT_DIR/compose-interpolation.after"
cp -a "$OVERLAY_TARGET" "$OUTPUT_DIR/docker-compose.spc001.after"

{
  echo "HEAD=$HEAD_SHA"
  echo "F3_HEAD=$F3_HEAD"
  echo "F3_EVIDENCE_DIR=$F3_DIR"
  echo "BOT_USERNAME=$BOT_USERNAME"
  echo "HAS_MAIN_WEB_APP=$HAS_MAIN_WEB_APP"
  echo "MONEYTRACK_INVITE_TTL_SECONDS=$INVITE_TTL_SECONDS"
  echo "MONEYTRACK_INVITE_BASE_URL=$INVITE_BASE_URL"
  echo 'CONFIG_SOURCE_PATCH=PASS'
  echo 'COMPOSE_INVITE_CONFIG=PASS'
  echo 'N8N_HEALTH=PASS'
  echo 'LIVE_INVITE_ENV=PASS'
  echo 'SEC001_PIN_PEPPER_PRESERVED=PASS'
  echo 'WORKFLOW_STATE_UNCHANGED=PASS'
  echo 'DB_MUTATION=NONE'
  echo 'N8N_MUTATION=CONFIG_RECREATE_APPLIED'
  echo 'N8N_WORKFLOW_IMPORT=NONE'
  echo 'N8N_WORKFLOW_PUBLISH=NONE'
  echo 'FRONTEND_MUTATION=NONE'
  echo 'SPC001_INVITE_RUNTIME_CONFIG=PASS'
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

SOURCE_MUTATED=0
RECREATE_ATTEMPTED=0
trap - ERR

echo "SPC001_INVITE_RUNTIME_EVIDENCE_DIR=$OUTPUT_DIR"
echo 'DB_MUTATION=NONE'
echo 'N8N_MUTATION=CONFIG_RECREATE_APPLIED'
echo 'N8N_WORKFLOW_IMPORT=NONE'
echo 'N8N_WORKFLOW_PUBLISH=NONE'
echo 'FRONTEND_MUTATION=NONE'
echo 'ROLLBACK_TRIGGERED=NO'
echo 'SPC001_INVITE_RUNTIME_CONFIG=PASS'
