#!/usr/bin/env python3
import copy
import hashlib
import json
import sys
from pathlib import Path

if len(sys.argv) != 3:
    raise SystemExit(
        "usage: be-dom-003-transform-user-lifecycle-cutover.py "
        "<main-before.json> <main-candidate.json>"
    )

src, dst = map(Path, sys.argv[1:])

def load_one(path):
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, list) or len(data) != 1:
        raise SystemExit(f"ERROR: expected one exported workflow in {path}")
    return data

def node_by_name(wf, name):
    matches = [n for n in wf["nodes"] if n.get("name") == name]
    if len(matches) != 1:
        raise SystemExit(f"ERROR: expected exactly one node {name!r}, found {len(matches)}")
    return matches[0]

def set_query(wf, name, query):
    node = node_by_name(wf, name)
    if node.get("type") != "n8n-nodes-base.postgres":
        raise SystemExit(f"ERROR: {name!r} is not a Postgres node")
    node.setdefault("parameters", {})["query"] = query.strip() + "\n"


data = load_one(src)
before = data[0]
after = copy.deepcopy(before)

# /start and ingress now share one canonical lifecycle bootstrap.
set_query(
    after,
    "Command Start",
    r"""
select
    b.user_id,
    b.telegram_user_id,
    b.language_code,
    b.base_currency,
    b.report_currency,
    b.workspace_id,
    b.workspace_role,
    b.default_expense_account_id,
    b.default_income_account_id
from moneytrack.user_bootstrap_v1(
    {{ $('Get user context').first().json.telegram_user_id }}::bigint,
    nullif('{{ String($('Get user context').first().json.telegram_username || "").replace(/'/g,"''") }}','')::text,
    nullif('{{ String($('Get user context').first().json.telegram_first_name || "").replace(/'/g,"''") }}','')::text,
    nullif('{{ String($('Get user context').first().json.telegram_language_code || "").replace(/'/g,"''") }}','')::text
) b;
""",
)

# Preserve the normalized transport output contract while delegating all lifecycle
# persistence to user_bootstrap_v1.
set_query(
    after,
    "Get or Create User",
    r"""
with input_data as (
    select
        {{ $json.telegram_user_id }}::bigint as telegram_user_id,
        {{ $json.telegram_chat_id }}::bigint as telegram_chat_id,
        nullif('{{ String($json.telegram_username || "").replace(/'/g,"''") }}','')::text as telegram_username,
        nullif('{{ String($json.telegram_first_name || "").replace(/'/g,"''") }}','')::text as telegram_first_name,
        nullif('{{ String($json.telegram_language_code || "").replace(/'/g,"''") }}','')::text as telegram_language_code,
        nullif('{{ String($json.message_text || "").replace(/'/g,"''") }}','')::text as message_text,
        nullif('{{ String($json.message_caption || "").replace(/'/g,"''") }}','')::text as message_caption,
        {{ $json.message_date || "null" }}::bigint as message_date,
        nullif('{{ String($json.message_type || "").replace(/'/g,"''") }}','')::text as message_type,
        nullif('{{ String($json.telegram_file_id || "").replace(/'/g,"''") }}','')::text as telegram_file_id,
        {{ $json.test_mode === true ? 'true' : 'false' }}::boolean as test_mode,
        $json${{ JSON.stringify($json.raw_message || {}) }}$json$::jsonb as raw_message
),
bootstrapped as (
    select b.*
    from input_data i
    cross join lateral moneytrack.user_bootstrap_v1(
        i.telegram_user_id,
        i.telegram_username,
        i.telegram_first_name,
        i.telegram_language_code
    ) b
)
select
    b.user_id,
    i.test_mode,
    i.telegram_user_id,
    i.telegram_chat_id,
    i.telegram_username,
    i.telegram_first_name,
    i.telegram_language_code,
    i.message_text,
    i.message_caption,
    i.message_date,
    i.message_type,
    i.telegram_file_id,
    i.raw_message,
    b.language_code,
    b.language_code as fallback_language_code,
    b.base_currency,
    b.report_currency,
    b.workspace_id,
    b.default_expense_account_id,
    b.default_income_account_id
from input_data i
cross join bootstrapped b;
""",
)

set_query(
    after,
    "Create Delete Me Request",
    r"""
select id, confirmation_code, expires_at
from moneytrack.user_create_delete_request_v1(
    {{ $('Get user context').first().json.user_id }}::bigint
);
""",
)

set_query(
    after,
    "Set default account",
    r"""
select
    currency_code,
    account_hint,
    account_name,
    account_code,
    status
from moneytrack.user_set_default_account_v1(
    {{ $('Get user context').first().json.user_id }}::bigint,
    {{ $json.currency_code ? "'" + String($json.currency_code).replace(/'/g,"''") + "'" : "null" }}::text,
    {{ $json.account_hint ? "'" + String($json.account_hint).replace(/'/g,"''") + "'" : "null" }}::text
);
""",
)

set_query(
    after,
    "Update Language",
    r"""
select
    requested_language_code,
    language_code,
    is_valid,
    status
from moneytrack.user_set_language_v1(
    {{ $('Get user context').first().json.user_id }}::bigint,
    {{ $json.language_code ? "'" + String($json.language_code).replace(/'/g,"''") + "'" : "null" }}::text
);
""",
)

set_query(
    after,
    "Update User Currency",
    r"""
select
    currency_type,
    currency_code,
    status,
    is_valid,
    base_currency,
    report_currency,
    available_currencies
from moneytrack.user_set_currency_v1(
    {{ $('Get user context').first().json.user_id }}::bigint,
    nullif('{{ String($json.currency_type || "").replace(/'/g,"''") }}','')::text,
    nullif('{{ String($json.currency_code || "").replace(/'/g,"''") }}','')::text
);
""",
)

data[0] = after
dst.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")

payload = json.dumps(
    after.get("connections", {}),
    ensure_ascii=False,
    sort_keys=True,
    separators=(",", ":"),
).encode()

print("main_candidate_created=", dst)
print("main_nodes=", len(after["nodes"]))
print("main_graph_sha256=", hashlib.sha256(payload).hexdigest())
print("status=PASS")
