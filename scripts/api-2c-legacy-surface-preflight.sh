#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

MINI_ID="7TJ2xQTxLsTydXZc"
MAIN_ID="DER2Lc3dT2afyQhy"

printf '=== API-2C / 1. ACTIVE ENDPOINT OWNERSHIP ===\n'
docker exec postgres psql -U n8n -d n8n -P pager=off -c "
with hooks as (
  select
    w.id workflow_id,
    w.name workflow_name,
    w.active,
    w.\"versionId\" version_id,
    w.\"activeVersionId\" active_version_id,
    w.\"versionCounter\" version_counter,
    n->>'name' node_name,
    upper(coalesce(n->'parameters'->>'httpMethod','GET')) method,
    '/' || ltrim(coalesce(n->'parameters'->>'path',''), '/') path
  from workflow_entity w
  cross join lateral jsonb_array_elements(w.nodes::jsonb) n
  where w.active=true
    and n->>'type'='n8n-nodes-base.webhook'
)
select workflow_id,workflow_name,node_name,method,path,active,
       (version_id=active_version_id) version_consistent,version_counter
from hooks
where (method='GET' and path in ('/api/v1/me','/api/v1/i18n'))
   or (method='POST' and path='/moneytrack-test')
order by path;
"

printf '\n=== API-2C / 2. WEBHOOK IMMEDIATE DOWNSTREAM ===\n'
docker exec postgres psql -U n8n -d n8n -P pager=off -c "
with target as (
  select w.id,w.name,w.nodes::jsonb nodes,w.connections::jsonb connections
  from workflow_entity w
  where w.active=true and w.id in ('$MINI_ID','$MAIN_ID')
), hooks as (
  select
    t.id workflow_id,
    t.name workflow_name,
    n->>'name' webhook_node,
    upper(coalesce(n->'parameters'->>'httpMethod','GET')) method,
    '/' || ltrim(coalesce(n->'parameters'->>'path',''), '/') path,
    t.connections
  from target t
  cross join lateral jsonb_array_elements(t.nodes) n
  where n->>'type'='n8n-nodes-base.webhook'
), selected as (
  select * from hooks
  where (method='GET' and path in ('/api/v1/me','/api/v1/i18n'))
     or (method='POST' and path='/moneytrack-test')
)
select workflow_id,workflow_name,webhook_node,method,path,
       coalesce(connections -> webhook_node -> 'main','[]'::jsonb) immediate_connections
from selected
order by path;
"

printf '\n=== API-2C / 3. REPOSITORY CALLER SEARCH ===\n'
refs=(
  "main"
  "origin/fix/restore-modern-preview-ui-20260806"
  "origin/agent/ux-022-accounts-explorer"
)
patterns=(
  "api/v1/me"
  "api/v1/i18n"
  "moneytrack-test"
)

for pattern in "${patterns[@]}"; do
  echo "--- pattern=$pattern ---"
  total=0
  for ref in "${refs[@]}"; do
    if ! git rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
      echo "ref=$ref unavailable"
      continue
    fi
    echo "ref=$ref"
    matches="$(git grep -n -F "$pattern" "$ref" -- ':!docs/**' ':!scripts/**' 2>/dev/null || true)"
    if [ -n "$matches" ]; then
      printf '%s\n' "$matches"
      count="$(printf '%s\n' "$matches" | wc -l)"
      total=$((total + count))
    else
      echo "(no matches)"
    fi
  done
  echo "repository_match_count[$pattern]=$total"
done

printf '\n=== API-2C / 4. AVAILABLE NGINX ACCESS-LOG USAGE ===\n'
log_files=()
while IFS= read -r f; do
  [ -n "$f" ] && log_files+=("$f")
done < <(find /var/log/nginx -maxdepth 1 -type f \( -name 'access.log' -o -name 'access.log.*' \) 2>/dev/null | sort || true)

if [ "${#log_files[@]}" -eq 0 ]; then
  echo "nginx_access_logs=UNAVAILABLE"
else
  echo "nginx_access_logs=${#log_files[@]}"
  printf 'log_file=%s\n' "${log_files[@]}"

  search_logs() {
    local needle="$1"
    local tmp
    tmp="$(mktemp)"
    : > "$tmp"
    for f in "${log_files[@]}"; do
      case "$f" in
        *.gz) zgrep -h -F "$needle" "$f" >> "$tmp" 2>/dev/null || true ;;
        *)    grep  -h -F "$needle" "$f" >> "$tmp" 2>/dev/null || true ;;
      esac
    done
    echo "access_log_hits[$needle]=$(wc -l < "$tmp" | tr -d ' ')"
    echo "latest_retained_lines[$needle]:"
    tail -n 10 "$tmp" || true
    rm -f "$tmp"
  }

  search_logs "/api/v1/me"
  search_logs "/api/v1/i18n"
  search_logs "/moneytrack-test"
fi

printf '\n=== API-2C / 5. WORKFLOW EXECUTION CONTEXT — NOT ENDPOINT-SPECIFIC ===\n'
docker exec postgres psql -U n8n -d n8n -P pager=off -c "
select
  \"workflowId\" workflow_id,
  count(*) filter (where \"startedAt\" >= now() - interval '30 days') executions_30d,
  max(\"startedAt\") last_execution_at
from execution_entity
where \"workflowId\" in ('$MINI_ID','$MAIN_ID')
group by \"workflowId\"
order by \"workflowId\";
"

echo "NOTE: workflow execution counts cannot distinguish which trigger/path started a multi-trigger workflow."

printf '\n=== API-2C / 6. GLOBAL ZERO-WRITER REASSERTION ===\n'
docker exec postgres psql -U n8n -d n8n -P pager=off -c "
with nodes as (
  select coalesce(n->'parameters'->>'query','') query_text
  from workflow_entity w
  cross join lateral jsonb_array_elements(w.nodes::jsonb) n
  where w.active=true
)
select count(*) as global_direct_business_writer_nodes
from nodes
where query_text ~*
  '(insert[[:space:][:cntrl:]]+into|update|delete[[:space:][:cntrl:]]+from)[[:space:][:cntrl:]]+moneytrack\\.[a-zA-Z_][a-zA-Z0-9_]*';
"

printf '\n=== API-2C / 7. N8N HEALTH ===\n'
curl -fsS --max-time 5 http://127.0.0.1:5678/healthz
echo

printf '\n=== API-2C LEGACY SURFACE PREFLIGHT COMPLETE ===\n'
