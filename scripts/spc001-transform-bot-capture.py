#!/usr/bin/env python3
"""SPC-001: fail-closed transform of the canonical trusted Telegram Bot workflow.

The accepted command/AI graph is preserved. Get user context is cut over to the
explicit default_capture_space_id backend resolver. A generated context node is
inserted immediately before each Text/Voice/Photo processor call so downstream
processor workflows receive actor + destination Space + stable capture source
without depending on upstream object-shaping details.
"""
from __future__ import annotations

import argparse
import copy
import json
import uuid
from pathlib import Path

WORKFLOW_ID = "DER2Lc3dT2afyQhy"
GET_CONTEXT = "Get user context"
PROCESSORS = {
    "Call 'Transaction Processor Text'": "text",
    "Call 'Transaction Processor Voice'": "voice",
    "Call 'Transaction Processor Photo'": "photo_receipt",
}
NS = uuid.UUID("d6e26a49-d2ff-44ba-a2bd-809139df69db")

BOT_CONTEXT_QUERY = r'''select
    b.actor_user_id::bigint as user_id,
    b.actor_user_id::bigint as actor_user_id,
    b.space_id::bigint as space_id,
    b.space_id::bigint as workspace_id,
    b.space_name::text as space_name,
    {{ $json.telegram_user_id }}::bigint as telegram_user_id,
    {{ $json.telegram_chat_id }}::bigint as telegram_chat_id,
    '{{ String($json.telegram_username || '').replace(/'/g,"''") }}'::text as telegram_username,
    '{{ String($json.telegram_first_name || '').replace(/'/g,"''") }}'::text as telegram_first_name,
    '{{ String($json.telegram_language_code || '').replace(/'/g,"''") }}'::text as telegram_language_code,
    b.language_code::text as language_code,
    b.fallback_language_code::text as fallback_language_code,
    b.base_currency::text as base_currency,
    b.report_currency::text as report_currency,
    b.default_expense_account_id::bigint as default_expense_account_id,
    b.default_income_account_id::bigint as default_income_account_id,
    '{{ String($json.message_text || '').replace(/'/g,"''") }}'::text as message_text,
    '{{ String($json.message_caption || '').replace(/'/g,"''") }}'::text as message_caption,
    {{ $json.message_date || 'null' }}::bigint as message_date,
    '{{ String($json.message_type || '').replace(/'/g,"''") }}'::text as message_type,
    '{{ String($json.telegram_file_id || '').replace(/'/g,"''") }}'::text as telegram_file_id,
    '{{ String('bot:' + ($json.telegram_chat_id ?? '') + ':' + ($json.raw_message?.message_id ?? $json.message_date ?? '')).replace(/'/g,"''") }}'::text as capture_source_ref,
    '{{ JSON.stringify($json.raw_message || {}).replaceAll("'", "''") }}'::jsonb as raw_message,
    {{ $json.test_mode ? 'true' : 'false' }}::boolean as test_mode
from moneytrack.bot_capture_context_v1(
    {{ $json.telegram_user_id }}::bigint
) b;'''


def uid(value: str) -> str:
    return str(uuid.uuid5(NS, value))


def context_js(kind: str) -> str:
    return f'''const context=$({json.dumps(GET_CONTEXT)}).first().json||{{}};
if(!context.user_id||!context.space_id||!context.capture_source_ref){{
  return [{{json:{{ok:false,http_status:500,error:{{code:"BOT_SPACE_CONTEXT_INVALID"}}}}}}];
}}
const items=$input.all();
return items.map((item)=>({{
  json:{{
    ...(item.json||{{}}),
    user_id:Number(context.user_id),
    actor_user_id:Number(context.user_id),
    space_id:Number(context.space_id),
    workspace_id:Number(context.space_id),
    space_name:context.space_name||null,
    capture_source_ref:String(context.capture_source_ref),
    source_type:{json.dumps(kind)},
    language_code:(item.json||{{}}).language_code||context.language_code||'en',
    fallback_language_code:(item.json||{{}}).fallback_language_code||context.fallback_language_code||context.language_code||'en',
    base_currency:(item.json||{{}}).base_currency||context.base_currency||'EUR',
    report_currency:(item.json||{{}}).report_currency||context.report_currency||context.base_currency||'EUR',
    default_expense_account_id:(item.json||{{}}).default_expense_account_id??context.default_expense_account_id??null,
    default_income_account_id:(item.json||{{}}).default_income_account_id??context.default_income_account_id??null
  }},
  binary:item.binary||{{}}
}}));'''


def unwrap(doc):
    if isinstance(doc, list):
        if len(doc) != 1:
            raise SystemExit(f"expected exactly one workflow, got {len(doc)}")
        return doc[0], True
    if isinstance(doc, dict):
        return doc, False
    raise SystemExit("input must be a workflow object or one-element workflow array")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("output")
    args = ap.parse_args()

    src = json.loads(Path(args.input).read_text(encoding="utf-8"))
    workflow, was_array = unwrap(src)
    if workflow.get("id") != WORKFLOW_ID:
        raise SystemExit(f"unexpected workflow id: {workflow.get('id')!r}")

    names = {n.get("name") for n in workflow.get("nodes", [])}
    required = {GET_CONTEXT, *PROCESSORS.keys()}
    missing = required - names
    if missing:
        raise SystemExit(f"missing canonical Bot nodes: {sorted(missing)}")

    out = copy.deepcopy(workflow)
    by_name = {n.get("name"): n for n in out.get("nodes", [])}
    context_node = by_name[GET_CONTEXT]
    params = context_node.setdefault("parameters", {})
    if context_node.get("type") != "n8n-nodes-base.postgres" or params.get("operation") != "executeQuery":
        raise SystemExit("Get user context is not the expected PostgreSQL executeQuery node")
    params["query"] = BOT_CONTEXT_QUERY

    inserted = []
    for processor_name, kind in PROCESSORS.items():
        processor = by_name[processor_name]
        x, y = processor.get("position", [0, 0])
        gate_name = f"SPC001 Bot {kind} Space Context"
        if gate_name in by_name:
            raise SystemExit(f"context node already exists: {gate_name}")

        gate = {
            "parameters": {"jsCode": context_js(kind)},
            "type": "n8n-nodes-base.code",
            "typeVersion": 2,
            "position": [x - 220, y],
            "id": uid(gate_name),
            "name": gate_name,
        }
        out.setdefault("nodes", []).append(gate)
        inserted.append(gate_name)

        incoming = 0
        for source_name, outputs in out.get("connections", {}).items():
            for output_group in outputs.get("main", []):
                for edge in output_group:
                    if edge.get("node") == processor_name:
                        edge["node"] = gate_name
                        incoming += 1
        if incoming == 0:
            raise SystemExit(f"processor has no incoming edge: {processor_name}")

        out.setdefault("connections", {})[gate_name] = {
            "main": [[{"node": processor_name, "type": "main", "index": 0}]]
        }

    # The legacy private commands must remain unavailable. This transform never
    # introduces command handlers and refuses a source snapshot that lacks the
    # accepted explicit restriction markers.
    source_text = json.dumps(workflow, ensure_ascii=False).lower()
    for command in ("/summary", "/last", "/settings"):
        if command not in source_text:
            raise SystemExit(f"canonical Bot command restriction marker missing: {command}")

    output = [out] if was_array else out
    Path(args.output).write_text(
        json.dumps(output, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print("SPC-001 Bot capture candidate created")
    print(f"workflow_id={WORKFLOW_ID}")
    print("context_query=bot_capture_context_v1")
    print("default_capture_space=explicit_only")
    print("inserted_nodes=" + ", ".join(sorted(inserted)))
    print("legacy_private_commands=preserved_unavailable")
    print("runtime_mutation=NONE")


if __name__ == "__main__":
    main()
