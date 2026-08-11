#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

N8N_CONTAINER="${MONEYTRACK_N8N_CONTAINER:-n8n}"
WORK="$(mktemp -d /tmp/ux022r3-execution-data.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo '# Phase'
echo 'UX-022R3 raw execution-data forensic: photo + transactions'
echo '# Gate'
echo 'READ_ONLY'
echo "HEAD=$(git rev-parse HEAD)"

docker inspect "$N8N_CONTAINER" >/dev/null

DB_TYPE="$(docker exec "$N8N_CONTAINER" sh -c 'printf "%s" "${DB_TYPE:-sqlite}"' 2>/dev/null || true)"
if [[ "$DB_TYPE" != 'postgresdb' && "$DB_TYPE" != 'postgres' ]]; then
  echo "n8n_db_type=${DB_TYPE:-unknown}"
  echo 'execution_data_forensic=UNSUPPORTED_DB_TYPE'
  exit 1
fi

PG_HOST="$(docker exec "$N8N_CONTAINER" sh -c 'printf "%s" "${DB_POSTGRESDB_HOST:-}"' 2>/dev/null || true)"
PG_PORT="$(docker exec "$N8N_CONTAINER" sh -c 'printf "%s" "${DB_POSTGRESDB_PORT:-5432}"' 2>/dev/null || true)"
PG_DB="$(docker exec "$N8N_CONTAINER" sh -c 'printf "%s" "${DB_POSTGRESDB_DATABASE:-n8n}"' 2>/dev/null || true)"
PG_USER="$(docker exec "$N8N_CONTAINER" sh -c 'printf "%s" "${DB_POSTGRESDB_USER:-}"' 2>/dev/null || true)"
PG_SCHEMA="$(docker exec "$N8N_CONTAINER" sh -c 'printf "%s" "${DB_POSTGRESDB_SCHEMA:-public}"' 2>/dev/null || true)"
PG_PASS="$(docker exec "$N8N_CONTAINER" sh -c 'printf "%s" "${DB_POSTGRESDB_PASSWORD:-}"' 2>/dev/null || true)"

if [[ -z "$PG_HOST" ]] || ! docker inspect "$PG_HOST" >/dev/null 2>&1; then
  echo 'n8n_postgres_container=UNAVAILABLE'
  exit 1
fi

# Raw execution_data is transferred as hex. No PostgreSQL regular expressions are used.
docker exec -e PGPASSWORD="$PG_PASS" "$PG_HOST" psql -X -qAt -F $'\t' \
  -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -c "
with ranked as (
  select
    e.id,
    e.\"workflowId\",
    e.status,
    e.\"startedAt\",
    row_number() over (partition by e.\"workflowId\" order by e.id desc) as rn
  from \"$PG_SCHEMA\".\"execution_entity\" e
  where e.\"workflowId\" in ('UX022TxApi202608','UX022QuickInput202608','5VC0EcFB21rwTfoI')
), chosen as (
  select * from ranked
  where (\"workflowId\"='5VC0EcFB21rwTfoI' and status <> 'success' and rn <= 20)
     or (\"workflowId\"='UX022QuickInput202608' and rn <= 12)
     or (\"workflowId\"='UX022TxApi202608' and rn <= 16)
)
select
  c.id,
  c.\"workflowId\",
  c.status,
  c.\"startedAt\",
  encode(convert_to(coalesce(d.data::text,''),'UTF8'),'hex')
from chosen c
join \"$PG_SCHEMA\".\"execution_data\" d on d.\"executionId\"=c.id
order by c.id desc;
" > "$WORK/executions.tsv"

python3 - "$WORK/executions.tsv" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
rows = []
for line in path.read_text(encoding='utf-8', errors='replace').splitlines():
    parts = line.split('\t', 4)
    if len(parts) != 5:
        continue
    eid, workflow, status, started, payload_hex = parts
    try:
        raw = bytes.fromhex(payload_hex).decode('utf-8', errors='replace')
    except ValueError:
        raw = ''
    rows.append((eid, workflow, status, started, raw))

print(f'execution_data_rows={len(rows)}')

sensitive = re.compile(
    r'(?is)(x-telegram-init-data|initdata|init_data|authorization|password|bot_token|token|hash)'
    r'(["\'\s:=]{1,12})([^,}\]\s]{8,2000})'
)

def redact(text: str) -> str:
    text = sensitive.sub(lambda m: f'{m.group(1)}{m.group(2)}<redacted>', text)
    text = re.sub(r'(?i)(Bearer\s+)[A-Za-z0-9._~+/=-]{12,}', r'\1<redacted>', text)
    return text.replace('\n', ' ')


def contexts(raw: str, markers, before=500, after=2200, limit=4):
    low = raw.lower()
    found = []
    for marker in markers:
        start = 0
        needle = marker.lower()
        while True:
            pos = low.find(needle, start)
            if pos < 0:
                break
            found.append((pos, marker))
            start = pos + max(1, len(needle))
    out = []
    used = []
    for pos, marker in sorted(found):
        if any(abs(pos - prev) < 600 for prev in used):
            continue
        used.append(pos)
        out.append((marker, redact(raw[max(0, pos-before):min(len(raw), pos+after)])))
        if len(out) >= limit:
            break
    return out

photo_rows = [r for r in rows if r[1] == '5VC0EcFB21rwTfoI' and r[2] != 'success']
print(f'photo_failed_execution_data_rows={len(photo_rows)}')
for eid, workflow, status, started, raw in photo_rows[:8]:
    print(f'photo_failed_execution id={eid} status={status} startedAt={started}')
    hits = contexts(raw, [
        'lastNodeExecuted', 'NodeOperationError', 'NodeApiError', 'error', 'message',
        'Check duplicate receipt', 'Check semantic duplicate receipt', 'PHOTO_',
        'invalid input', 'does not exist', 'syntax error', 'operator does not exist'
    ], limit=5)
    if not hits:
        print(f'photo_error_context id={eid} marker=NONE')
    for marker, snippet in hits:
        print(f'photo_error_context id={eid} marker={marker} snippet={snippet}')

quick_rows = [r for r in rows if r[1] == 'UX022QuickInput202608']
for eid, workflow, status, started, raw in quick_rows[:6]:
    flags = {
        'DOMAIN_ERROR': 'domain_error' in raw.lower(),
        'RECEIPT_DUPLICATE': 'receipt_duplicate' in raw.lower(),
        'PHOTO_BINARY_MISSING': 'photo_binary_missing' in raw.lower(),
    }
    print('quick_execution_flags id={} status={} startedAt={} {}'.format(
        eid, status, started, ' '.join(f'{k}={"YES" if v else "NO"}' for k,v in flags.items())
    ))
    for marker, snippet in contexts(raw, ['DOMAIN_ERROR','http_status','error','Photo Format'], limit=2):
        print(f'quick_context id={eid} marker={marker} snippet={snippet}')

tx_rows = [r for r in rows if r[1] == 'UX022TxApi202608']
for eid, workflow, status, started, raw in tx_rows[:10]:
    low = raw.lower()
    print(
        f'tx_execution_flags id={eid} status={status} startedAt={started} '
        f'contains_752={"YES" if "752" in raw else "NO"} '
        f'contains_100={"YES" if "100" in raw else "NO"} '
        f'contains_expense={"YES" if "expense" in low else "NO"}'
    )
    for marker, snippet in contexts(
        raw,
        ['account_id','date_from','date_to','selected_account_ids','summary','expense','752'],
        before=420,
        after=1700,
        limit=4,
    ):
        print(f'tx_context id={eid} marker={marker} snippet={snippet}')

print('N8N_MUTATION=NONE')
print('DB_MUTATION=NONE')
print('FRONTEND_MUTATION=NONE')
print('UX022R3_EXECUTION_DATA_FORENSIC=PASS')
PY
