#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PSQL=(docker exec -i postgres psql -U n8n -d n8n -P pager=off)

echo "=== API-1 / 1. REPOSITORY BASELINE ==="
printf 'repo_head='
git rev-parse HEAD
printf 'repo_branch='
git branch --show-current
printf 'repo_status=' 
if [ -z "$(git status --porcelain)" ]; then
  echo CLEAN
else
  echo DIRTY
  git status --short
fi


echo
echo "=== API-1 / 2. KNOWN API WORKFLOW ANCHORS ==="
"${PSQL[@]}" <<'SQL'
with anchors(workflow_id, expected_role) as (
    values
      ('7TJ2xQTxLsTydXZc', 'MiniApp API'),
      ('MTxDel7Qp2Vn9Kc4', 'MiniApp transaction delete'),
      ('MTxRef4Qp8Lm2Xs6', 'MiniApp transaction reference'),
      ('UX022Summary202608', 'Accounts Explorer summary'),
      ('UX022TxApi202608', 'Transactions API')
)
select
    a.workflow_id,
    a.expected_role,
    coalesce(w.name, '<missing>') as runtime_name,
    coalesce(w.active, false) as active,
    w."versionId",
    w."activeVersionId",
    case
      when w.id is null then false
      else w."versionId" = w."activeVersionId"
    end as version_consistent
from anchors a
left join workflow_entity w
  on w.id = a.workflow_id
order by a.workflow_id;
SQL


echo
echo "=== API-1 / 3. ACTIVE HTTP WEBHOOK ENDPOINTS ==="
"${PSQL[@]}" <<'SQL'
with webhooks as (
    select
        w.id as workflow_id,
        w.name as workflow_name,
        w.active,
        w."versionId",
        w."activeVersionId",
        w."versionCounter",
        n->>'name' as node_name,
        upper(coalesce(nullif(n->'parameters'->>'httpMethod',''), 'GET')) as method,
        n->'parameters'->>'path' as path,
        coalesce(nullif(n->'parameters'->>'authentication',''), 'none') as authentication,
        coalesce(nullif(n->'parameters'->>'responseMode',''), 'onReceived') as response_mode
    from workflow_entity w
    cross join lateral jsonb_array_elements(w.nodes::jsonb) n
    where w.active = true
      and n->>'type' = 'n8n-nodes-base.webhook'
)
select
    workflow_id,
    workflow_name,
    node_name,
    method,
    path,
    authentication,
    response_mode,
    "versionId" = "activeVersionId" as version_consistent,
    "versionCounter"
from webhooks
order by path, method, workflow_name, node_name;
SQL


echo
echo "=== API-1 / 4. ENDPOINT COLLISION GATE ==="
"${PSQL[@]}" <<'SQL'
with webhooks as (
    select
        w.id as workflow_id,
        w.name as workflow_name,
        upper(coalesce(nullif(n->'parameters'->>'httpMethod',''), 'GET')) as method,
        n->'parameters'->>'path' as path
    from workflow_entity w
    cross join lateral jsonb_array_elements(w.nodes::jsonb) n
    where w.active = true
      and n->>'type' = 'n8n-nodes-base.webhook'
), duplicates as (
    select
        method,
        path,
        count(*) as endpoint_count,
        string_agg(workflow_id || ':' || workflow_name, ' | ' order by workflow_id) as owners
    from webhooks
    group by method, path
    having count(*) > 1
)
select * from duplicates order by path, method;
SQL


echo
echo "=== API-1 / 5. API WORKFLOW NODE MIX ==="
"${PSQL[@]}" <<'SQL'
with api_workflows as (
    select distinct w.id
    from workflow_entity w
    cross join lateral jsonb_array_elements(w.nodes::jsonb) n
    where w.active = true
      and n->>'type' = 'n8n-nodes-base.webhook'
)
select
    w.id as workflow_id,
    w.name as workflow_name,
    count(*) as total_nodes,
    count(*) filter (where n->>'type' = 'n8n-nodes-base.webhook') as webhook_nodes,
    count(*) filter (where n->>'type' = 'n8n-nodes-base.postgres') as postgres_nodes,
    count(*) filter (where n->>'type' = 'n8n-nodes-base.code') as code_nodes,
    count(*) filter (where n->>'type' = 'n8n-nodes-base.respondToWebhook') as response_nodes
from workflow_entity w
join api_workflows aw on aw.id = w.id
cross join lateral jsonb_array_elements(w.nodes::jsonb) n
group by w.id, w.name
order by w.name, w.id;
SQL


echo
echo "=== API-1 / 6. POSTGRES NODES: BOUNDARY VS DIRECT READ ==="
"${PSQL[@]}" <<'SQL'
with api_workflows as (
    select distinct w.id
    from workflow_entity w
    cross join lateral jsonb_array_elements(w.nodes::jsonb) n
    where w.active = true
      and n->>'type' = 'n8n-nodes-base.webhook'
), pg_nodes as (
    select
        w.id as workflow_id,
        w.name as workflow_name,
        n->>'name' as node_name,
        coalesce(n->'parameters'->>'query','') as query_text
    from workflow_entity w
    join api_workflows aw on aw.id = w.id
    cross join lateral jsonb_array_elements(w.nodes::jsonb) n
    where n->>'type' = 'n8n-nodes-base.postgres'
)
select
    workflow_id,
    workflow_name,
    node_name,
    case
      when query_text ~* 'moneytrack\.[a-zA-Z_][a-zA-Z0-9_]*_v1[[:space:]]*\('
        then 'BACKEND_BOUNDARY'
      when query_text ~* '\mselect\M'
       and query_text ~* 'moneytrack\.'
        then 'DIRECT_READ_SQL'
      when btrim(query_text) = ''
        then 'EMPTY_OR_NON_QUERY_OPERATION'
      else 'SQL_OTHER'
    end as classification,
    left(regexp_replace(query_text, '[[:space:][:cntrl:]]+', ' ', 'g'), 180) as query_preview
from pg_nodes
order by workflow_name, node_name;
SQL


echo
echo "=== API-1 / 7. BACKEND BOUNDARY CALLS BY API WORKFLOW ==="
"${PSQL[@]}" <<'SQL'
with api_workflows as (
    select distinct w.id
    from workflow_entity w
    cross join lateral jsonb_array_elements(w.nodes::jsonb) n
    where w.active = true
      and n->>'type' = 'n8n-nodes-base.webhook'
), pg_nodes as (
    select
        w.id as workflow_id,
        w.name as workflow_name,
        n->>'name' as node_name,
        coalesce(n->'parameters'->>'query','') as query_text
    from workflow_entity w
    join api_workflows aw on aw.id = w.id
    cross join lateral jsonb_array_elements(w.nodes::jsonb) n
    where n->>'type' = 'n8n-nodes-base.postgres'
), calls as (
    select
        workflow_id,
        workflow_name,
        node_name,
        regexp_matches(
            query_text,
            '(?i)moneytrack\.([a-zA-Z_][a-zA-Z0-9_]*_v1)[[:space:]]*\(',
            'g'
        ) as m
    from pg_nodes
)
select
    workflow_id,
    workflow_name,
    node_name,
    lower(m[1]) as backend_boundary
from calls
order by workflow_name, node_name, backend_boundary;
SQL


echo
echo "=== API-1 / 8. CODE NODES INSIDE API WORKFLOWS ==="
"${PSQL[@]}" <<'SQL'
with api_workflows as (
    select distinct w.id
    from workflow_entity w
    cross join lateral jsonb_array_elements(w.nodes::jsonb) n
    where w.active = true
      and n->>'type' = 'n8n-nodes-base.webhook'
)
select
    w.id as workflow_id,
    w.name as workflow_name,
    n->>'name' as node_name,
    length(
      coalesce(
        n->'parameters'->>'jsCode',
        n->'parameters'->>'code',
        ''
      )
    ) as code_chars
from workflow_entity w
join api_workflows aw on aw.id = w.id
cross join lateral jsonb_array_elements(w.nodes::jsonb) n
where n->>'type' = 'n8n-nodes-base.code'
order by workflow_name, node_name;
SQL


echo
echo "=== API-1 / 9. DIRECT BUSINESS WRITER REASSERTION ==="
"${PSQL[@]}" <<'SQL'
with nodes as (
    select
        w.id as workflow_id,
        w.name as workflow_name,
        n->>'name' as node_name,
        coalesce(n->'parameters'->>'query','') as query_text
    from workflow_entity w
    cross join lateral jsonb_array_elements(w.nodes::jsonb) n
    where w.active = true
), mutations as (
    select
        workflow_id,
        workflow_name,
        node_name,
        regexp_matches(
            query_text,
            '(?i)(insert[[:space:][:cntrl:]]+into|update|delete[[:space:][:cntrl:]]+from)[[:space:][:cntrl:]]+moneytrack\.([a-zA-Z_][a-zA-Z0-9_]*)',
            'g'
        ) as m
    from nodes
)
select
    workflow_id,
    workflow_name,
    node_name,
    lower(m[1]) as operation,
    lower(m[2]) as table_name
from mutations
order by workflow_name, node_name, table_name;
SQL


echo
echo "=== API-1 / 10. ACTIVE HTTP ENDPOINT COUNT ==="
"${PSQL[@]}" <<'SQL'
select count(*) as active_http_endpoints
from workflow_entity w
cross join lateral jsonb_array_elements(w.nodes::jsonb) n
where w.active = true
  and n->>'type' = 'n8n-nodes-base.webhook';
SQL


echo
echo "=== API-1 / 11. FRONTEND CONSUMERS BY REPOSITORY REF ==="

# Read-only fetch: API-1 needs caller inventory from the frontend branches that
# are currently relevant to MoneyTrack UI work. Missing refs are reported, not
# treated as an error.
git fetch --no-tags origin \
  main \
  fix/restore-modern-preview-ui-20260806 \
  agent/ux-022-accounts-explorer \
  >/dev/null 2>&1 || true

REFS=(
  origin/main
  origin/fix/restore-modern-preview-ui-20260806
  origin/agent/ux-022-accounts-explorer
)

for ref in "${REFS[@]}"; do
  echo "--- ref=$ref ---"
  if ! git rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
    echo "REF_MISSING"
    continue
  fi

  git grep -nE '/api/v1/|/webhook/' "$ref" -- miniapp 2>/dev/null || echo "NO_API_CALLS_FOUND"
done


echo
echo "=== API-1 / 12. WORKFLOW SOURCE API PATHS BY REPOSITORY REF ==="
for ref in "${REFS[@]}"; do
  echo "--- ref=$ref ---"
  if ! git rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
    echo "REF_MISSING"
    continue
  fi

  git grep -nE 'api/v1/|webhook/' "$ref" -- workflows 2>/dev/null || echo "NO_WORKFLOW_API_PATHS_FOUND"
done


echo
echo "=== API-1 / 13. N8N HEALTH ==="
curl -fsS --max-time 5 http://127.0.0.1:5678/healthz
echo


echo "=== API-1 BOUNDED INVENTORY COMPLETE ==="
