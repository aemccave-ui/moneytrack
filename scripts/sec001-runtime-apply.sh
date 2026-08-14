#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

: "${SEC001_EXPECTED_HEAD:?SEC001_EXPECTED_HEAD is required}"
: "${SEC001_BACKUP_DIR:?SEC001_BACKUP_DIR is required}"

MANIFEST="$ROOT/ops/sec001/runtime-manifest.json"
BUILDER="$ROOT/scripts/sec001-build-live-candidates.py"
SEC_SQL="$ROOT/db/domain/SEC-001/010_application_lock.sql"

N8N_CONTAINER="${N8N_CONTAINER:-n8n}"
N8N_DB_CONTAINER="${N8N_DB_CONTAINER:-postgres}"
MT_DB_CONTAINER="${MT_DB_CONTAINER:-moneytrack-db}"

STACK=/root/stack/n8n
BASE_COMPOSE="$STACK/docker-compose.yml"
HARDENING_COMPOSE="$STACK/docker-compose.prod-h.yml"
SEC_OVERLAY="$STACK/docker-compose.sec001.yml"
SEC_OVERLAY_SOURCE="$ROOT/ops/sec001/docker-compose.sec001.yml"
INTERPOLATION="$STACK/compose-interpolation.prod-h.sh"

INSTALLED_BACKUP=/usr/local/lib/moneytrack/prod-h2-backup-now.sh

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ROLLBACK_DIR="/var/backups/moneytrack/sec001/$STAMP"
CANDIDATE_DIR="$(mktemp -d)"
VERIFY_DIR="$(mktemp -d)"

MUTATED=0
SECURITY_PUBLISHED=0
TOUCHED=()

cleanup() {
  rm -rf "$CANDIDATE_DIR" "$VERIFY_DIR"
}

import_publish() {
  local file="$1"
  local id="$2"
  local name
  name="$(basename "$file")"

  docker cp "$file" "$N8N_CONTAINER:/tmp/$name" >/dev/null
  docker exec "$N8N_CONTAINER" \
    n8n import:workflow --input="/tmp/$name"
  docker exec "$N8N_CONTAINER" \
    n8n publish:workflow --id="$id"
}

restore_existing_workflows() {
  local i id
  for ((i=${#TOUCHED[@]}-1; i>=0; i--)); do
    id="${TOUCHED[$i]}"
    if [[ -s "$ROLLBACK_DIR/$id.json" ]]; then
      import_publish "$ROLLBACK_DIR/$id.json" "$id" \
        || echo "ROLLBACK_WORKFLOW=FAIL id=$id" >&2
    fi
  done
}

rollback() {
  local rc=$?
  trap - ERR

  echo "ROLLBACK_TRIGGERED=YES rc=$rc" >&2

  if (( SECURITY_PUBLISHED )); then
    docker exec "$N8N_CONTAINER" \
      n8n unpublish:workflow --id=SEC001SecurityAPI202608 \
      >/dev/null 2>&1 \
      || echo "ROLLBACK_SECURITY_UNPUBLISH=FAIL" >&2
  fi

  if (( MUTATED )); then
    restore_existing_workflows

    if [[ -s "$ROLLBACK_DIR/compose-interpolation.before" ]]; then
      cp -a \
        "$ROLLBACK_DIR/compose-interpolation.before" \
        "$INTERPOLATION"
    fi

    if [[ -s "$ROLLBACK_DIR/docker-compose.sec001.before" ]]; then
      cp -a \
        "$ROLLBACK_DIR/docker-compose.sec001.before" \
        "$SEC_OVERLAY"
    else
      rm -f "$SEC_OVERLAY"
    fi

    if [[ -s "$ROLLBACK_DIR/prod-h2-backup-now.before" ]]; then
      cp -a \
        "$ROLLBACK_DIR/prod-h2-backup-now.before" \
        "$INSTALLED_BACKUP"
    fi

    (
      set -a
      # shellcheck source=/dev/null
      source "$INTERPOLATION"
      set +a

      docker compose -p n8n \
        -f "$BASE_COMPOSE" \
        -f "$HARDENING_COMPOSE" \
        up -d n8n >/dev/null
    ) || echo "ROLLBACK_N8N_RECREATE=FAIL" >&2

    docker restart "$N8N_CONTAINER" >/dev/null 2>&1 \
      || echo "ROLLBACK_N8N_RESTART=FAIL" >&2
  fi

  echo "ROLLBACK_SEC_DB_SCHEMA=LEFT_IDEMPOTENT" >&2
  echo "ROLLBACK_POINT=$ROLLBACK_DIR" >&2
  cleanup
  exit "$rc"
}

trap rollback ERR
trap cleanup EXIT

echo "=== SEC-001 CONTROLLED RUNTIME APPLY ==="

test "$(git rev-parse HEAD)" = "$SEC001_EXPECTED_HEAD" || {
  echo "RESULT=FAIL reason=unexpected_source_head"
  exit 1
}

test -z "$(git status --porcelain=v1)" || {
  echo "RESULT=FAIL reason=dirty_worktree"
  exit 1
}

for c in "$N8N_CONTAINER" "$N8N_DB_CONTAINER" "$MT_DB_CONTAINER"; do
  test "$(docker inspect -f '{{.State.Running}}' "$c")" = true || {
    echo "RESULT=FAIL reason=container_not_running container=$c"
    exit 1
  }
done

for f in \
  "$BASE_COMPOSE" \
  "$HARDENING_COMPOSE" \
  "$INTERPOLATION" \
  "$MANIFEST" \
  "$SEC_OVERLAY_SOURCE" \
  "$SEC_SQL"; do
  test -f "$f" || {
    echo "RESULT=FAIL reason=missing_file file=$f"
    exit 1
  }
done

test -f "$SEC001_BACKUP_DIR/COMPLETE" || {
  echo "RESULT=FAIL reason=backup_complete_marker_missing"
  exit 1
}

test -s "$SEC001_BACKUP_DIR/SHA256SUMS" || {
  echo "RESULT=FAIL reason=backup_hash_manifest_missing"
  exit 1
}

(
  cd "$SEC001_BACKUP_DIR"
  sha256sum -c SHA256SUMS
)

echo "VERIFIED_BACKUP=PASS path=$SEC001_BACKUP_DIR"

for command_name in python3 docker openssl curl; do
  command -v "$command_name" >/dev/null || {
    echo "RESULT=FAIL reason=missing_command command=$command_name"
    exit 1
  }
done

for cli in \
  "export:workflow --help" \
  "import:workflow --help" \
  "publish:workflow --help" \
  "unpublish:workflow --help"; do
  docker exec "$N8N_CONTAINER" n8n $cli >/dev/null 2>&1 || {
    echo "RESULT=FAIL reason=n8n_cli_missing cli=$cli"
    exit 1
  }
done

docker exec "$N8N_CONTAINER" \
  n8n export:workflow --help 2>&1 |
  grep -Fq -- '--published'

echo "N8N_CLI_GATE=PASS"

python3 - "$MANIFEST" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text())

expected = {
    manifest["bot"]["id"]: manifest["bot"]["activeVersionId"]
}
expected.update({
    x["id"]: x["activeVersionId"]
    for x in manifest["apiWorkflows"]
})

sql = """
select (j->>'id') || E'\\t' || coalesce(j->>'activeVersionId','')
from (select to_jsonb(x) j from workflow_entity x) q
where coalesce((j->>'active')::boolean,false)
order by j->>'id';
"""

p = subprocess.run(
    [
        "docker", "exec", "-i", "postgres",
        "psql", "-X", "-q", "-At",
        "-v", "ON_ERROR_STOP=1",
        "-U", "n8n", "-d", "n8n",
    ],
    input=sql,
    text=True,
    stdout=subprocess.PIPE,
    check=True,
)

actual = {}
for line in p.stdout.splitlines():
    if "\t" in line:
        k, v = line.split("\t", 1)
        actual[k] = v

bad = {
    k: (actual.get(k), v)
    for k, v in expected.items()
    if actual.get(k) != v
}

if bad:
    raise SystemExit(
        "RUNTIME_VERSION_GUARD=FAIL " + json.dumps(bad, sort_keys=True)
    )

print("RUNTIME_VERSION_GUARD=PASS")
PY

mkdir -p "$ROLLBACK_DIR"
chmod 700 "$ROLLBACK_DIR"

cp -a "$INTERPOLATION" \
  "$ROLLBACK_DIR/compose-interpolation.before"

if [[ -f "$SEC_OVERLAY" ]]; then
  cp -a "$SEC_OVERLAY" \
    "$ROLLBACK_DIR/docker-compose.sec001.before"
fi

if [[ -f "$INSTALLED_BACKUP" ]]; then
  cp -a "$INSTALLED_BACKUP" \
    "$ROLLBACK_DIR/prod-h2-backup-now.before"
fi

mapfile -t WORKFLOW_IDS < <(
  python3 - "$MANIFEST" <<'PY'
import json, sys
from pathlib import Path
m=json.loads(Path(sys.argv[1]).read_text())
for x in m["apiWorkflows"]:
    print(x["id"])
print(m["bot"]["id"])
PY
)

for id in "${WORKFLOW_IDS[@]}"; do
  docker exec "$N8N_CONTAINER" \
    rm -f "/tmp/sec001-$id.json"

  docker exec "$N8N_CONTAINER" \
    n8n export:workflow \
      --id="$id" \
      --published \
      --output="/tmp/sec001-$id.json"

  docker cp \
    "$N8N_CONTAINER:/tmp/sec001-$id.json" \
    "$ROLLBACK_DIR/$id.json" >/dev/null

  test -s "$ROLLBACK_DIR/$id.json"
done

echo "PUBLISHED_WORKFLOW_BACKUP=PASS count=${#WORKFLOW_IDS[@]}"

python3 "$BUILDER" \
  --manifest "$MANIFEST" \
  --export-dir "$ROLLBACK_DIR" \
  --out-dir "$CANDIDATE_DIR"

echo "CANDIDATE_BUILD=PASS"

# No runtime mutation occurred before this point.
MUTATED=1

docker exec -i "$MT_DB_CONTAINER" \
  psql -X -q \
    -v ON_ERROR_STOP=1 \
    -U moneytrack \
    -d moneytrack \
  < "$SEC_SQL"

echo "SEC_DB_APPLY=PASS"

if ! grep -Eq '^(export[[:space:]]+)?MONEYTRACK_PIN_PEPPER=' "$INTERPOLATION"; then
  umask 077
  PEPPER="$(openssl rand -hex 32)"
  {
    echo
    echo "# SEC-001 application-lock server pepper"
    printf "export MONEYTRACK_PIN_PEPPER='%s'\n" "$PEPPER"
  } >> "$INTERPOLATION"
  unset PEPPER
fi

chmod 600 "$INTERPOLATION"

(
  set -a
  # shellcheck source=/dev/null
  source "$INTERPOLATION"
  set +a

  test "${#MONEYTRACK_PIN_PEPPER}" -ge 32
)

echo "MONEYTRACK_PIN_PEPPER=SET"

install -m 0644 \
  "$SEC_OVERLAY_SOURCE" \
  "$SEC_OVERLAY"

install -m 0755 \
  "$ROOT/scripts/prod-h2-backup-now.sh" \
  "$INSTALLED_BACKUP"

(
  set -a
  # shellcheck source=/dev/null
  source "$INTERPOLATION"
  set +a

  docker compose -p n8n \
    -f "$BASE_COMPOSE" \
    -f "$HARDENING_COMPOSE" \
    -f "$SEC_OVERLAY" \
    config >/dev/null

  docker compose -p n8n \
    -f "$BASE_COMPOSE" \
    -f "$HARDENING_COMPOSE" \
    -f "$SEC_OVERLAY" \
    up -d n8n >/dev/null
)

PEPPER_STATE="$(
  docker inspect "$N8N_CONTAINER" \
    --format '{{range .Config.Env}}{{println .}}{{end}}' |
  awk -F= '
    $1=="MONEYTRACK_PIN_PEPPER" && length(substr($0,index($0,"=")+1))>0 {
      found=1
    }
    END { print found ? "SET" : "UNSET" }
  '
)"

test "$PEPPER_STATE" = SET || {
  echo "RESULT=FAIL reason=pepper_not_in_container"
  exit 1
}

echo "N8N_SEC_ENV=PASS"

mapfile -t API_IDS < <(
  python3 - "$MANIFEST" <<'PY'
import json, sys
from pathlib import Path
m=json.loads(Path(sys.argv[1]).read_text())
for x in m["apiWorkflows"]:
    print(x["id"])
PY
)

for id in "${API_IDS[@]}"; do
  import_publish \
    "$CANDIDATE_DIR/$id.candidate.json" \
    "$id"
  TOUCHED+=("$id")
done

BOT_ID="$(
  python3 - "$MANIFEST" <<'PY'
import json, sys
from pathlib import Path
print(json.loads(Path(sys.argv[1]).read_text())["bot"]["id"])
PY
)"

import_publish \
  "$CANDIDATE_DIR/$BOT_ID.candidate.json" \
  "$BOT_ID"
TOUCHED+=("$BOT_ID")

# Security API is intentionally published last:
# all Class B surfaces are already protected before PIN can be enabled.
import_publish \
  "$CANDIDATE_DIR/SEC001SecurityAPI202608.candidate.json" \
  SEC001SecurityAPI202608

SECURITY_PUBLISHED=1

docker restart "$N8N_CONTAINER" >/dev/null

for _ in $(seq 1 30); do
  code="$(
    curl -sS -o /dev/null -w '%{http_code}' \
      http://127.0.0.1:5678/healthz || true
  )"
  [[ "$code" == 200 ]] && break
  sleep 1
done

test "${code:-}" = 200 || {
  echo "RESULT=FAIL reason=n8n_health_after_apply http=${code:-none}"
  exit 1
}

rm -rf "$VERIFY_DIR"
mkdir -p "$VERIFY_DIR"

for id in "${WORKFLOW_IDS[@]}" SEC001SecurityAPI202608; do
  docker exec "$N8N_CONTAINER" \
    rm -f "/tmp/sec001-verify-$id.json"

  docker exec "$N8N_CONTAINER" \
    n8n export:workflow \
      --id="$id" \
      --published \
      --output="/tmp/sec001-verify-$id.json"

  docker cp \
    "$N8N_CONTAINER:/tmp/sec001-verify-$id.json" \
    "$VERIFY_DIR/$id.json" >/dev/null
done

python3 "$BUILDER" \
  --verify-applied \
  --manifest "$MANIFEST" \
  --export-dir "$VERIFY_DIR"

SEC_TABLES="$(
  docker exec "$MT_DB_CONTAINER" \
    psql -X -q -At \
      -U moneytrack -d moneytrack \
      -c "
        select count(*)
        from information_schema.tables
        where table_schema='moneytrack'
          and table_name in (
            'user_security',
            'user_unlock_sessions',
            'user_biometric_credentials'
          );
      "
)"

test "$SEC_TABLES" = 3 || {
  echo "RESULT=FAIL reason=sec_db_tables count=$SEC_TABLES"
  exit 1
}

echo "SEC_DB_VERIFY=PASS"
echo "N8N_RUNTIME_VERIFY=PASS"
echo "ROLLBACK_POINT=$ROLLBACK_DIR"
echo "DB_MUTATION=APPLIED"
echo "N8N_MUTATION=APPLIED"
echo "PREVIEW_MUTATION=NONE"
echo "PRODUCTION_MUTATION=NONE"
echo "SEC001_RUNTIME_APPLY=PASS"
echo "RESULT=PASS"

trap - ERR
