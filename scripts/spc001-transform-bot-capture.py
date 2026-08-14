#!/usr/bin/env python3
"""SPC-001: fail-closed transform of canonical trusted Telegram Bot context.

The accepted MoneyTrack runtime delegates Text and Voice to processor
subworkflows and may delegate Photo to the accepted Photo processor while the
tracked rollback/evidence source can still retain the older inline Photo graph.
This transform therefore changes the shared Get user context boundary and
inserts Space context immediately before every delegated capture processor call
that is actually present. Inline Photo tenancy remains owned by the separate
inline transform/audit when no delegated Photo call exists.
"""
from __future__ import annotations

import argparse
import copy
import json
import uuid
from pathlib import Path
from typing import Any

WORKFLOW_ID = "DER2Lc3dT2afyQhy"
GET_CONTEXT = "Get user context"
PROCESSORS = {
    "Call 'Transaction Processor Text'": "text",
    "Call 'Transaction Processor Voice'": "voice",
}
PHOTO_PROCESSOR = "Call 'Transaction Processor Photo'"
EXPECTED_PHOTO_WORKFLOW_ID = "5VC0EcFB21rwTfoI"
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


def workflow_id_from_parameter(value: Any) -> str | None:
    if isinstance(value, str):
        text = value.strip()
        return text or None
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, dict):
        for key in ("value", "id", "workflowId"):
            if key in value:
                found = workflow_id_from_parameter(value[key])
                if found:
                    return found
    return None


def delegated_workflow_id(node: dict[str, Any]) -> str:
    if node.get("type") != "n8n-nodes-base.executeWorkflow":
        raise SystemExit(
            f"delegated processor {node.get('name')!r} has unexpected type={node.get('type')!r}"
        )
    params = node.get("parameters", {})
    for candidate in (params.get("workflowId"), params.get("workflow"), params.get("id")):
        found = workflow_id_from_parameter(candidate)
        if found:
            return found
    raise SystemExit(f"delegated processor workflow id unresolved: {node.get('name')!r}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("output")
    args = ap.parse_args()

    src = json.loads(Path(args.input).read_text(encoding="utf-8"))
    workflow, was_array = unwrap(src)
    if workflow.get("id") != WORKFLOW_ID:
        raise SystemExit(f"unexpected workflow id: {workflow.get('id')!r}")

    by_source_name = {n.get("name"): n for n in workflow.get("nodes", [])}
    names = set(by_source_name)
    required = {GET_CONTEXT, *PROCESSORS.keys()}
    missing = required - names
    if missing:
        raise SystemExit(f"missing canonical Bot nodes: {sorted(missing)}")

    processors = dict(PROCESSORS)
    if PHOTO_PROCESSOR in names:
        photo_workflow_id = delegated_workflow_id(by_source_name[PHOTO_PROCESSOR])
        if photo_workflow_id != EXPECTED_PHOTO_WORKFLOW_ID:
            raise SystemExit(
                "Photo processor workflow id drift: "
                f"expected={EXPECTED_PHOTO_WORKFLOW_ID} actual={photo_workflow_id}"
            )
        processors[PHOTO_PROCESSOR] = "photo"
        photo_topology = "delegated"
    else:
        inline_photo_required = {
            "Analyze image",
            "Parse receipt JSON",
            "Resolve account",
            "Insert transaction",
            "Insert receipt",
            "Create products",
        }
        missing_inline = inline_photo_required - names
        if missing_inline:
            raise SystemExit(f"inline Photo topology drift: missing={sorted(missing_inline)}")
        photo_topology = "inline"

    out = copy.deepcopy(workflow)
    by_name = {n.get("name"): n for n in out.get("nodes", [])}
    context_node = by_name[GET_CONTEXT]
    params = context_node.setdefault("parameters", {})
    if context_node.get("type") != "n8n-nodes-base.postgres" or params.get("operation") != "executeQuery":
        raise SystemExit("Get user context is not the expected PostgreSQL executeQuery node")
    params["query"] = BOT_CONTEXT_QUERY

    inserted = []
    for processor_name, kind in processors.items():
        processor = by_name[processor_name]
        if processor.get("type") != "n8n-nodes-base.executeWorkflow":
            raise SystemExit(
                f"processor node type drift name={processor_name!r} type={processor.get('type')!r}"
            )
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
        for _source_name, outputs in out.get("connections", {}).items():
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
    print("processor_context=" + "_".join(sorted(processors.values())))
    print(f"photo_topology={photo_topology}")
    if photo_topology == "inline":
        print("inline_photo=DELEGATED_TO_INLINE_PHOTO_TRANSFORM")
    else:
        print(f"photo_processor_id={EXPECTED_PHOTO_WORKFLOW_ID}")
        print("inline_photo=LEGACY_GRAPH_LEFT_FOR_REACHABILITY_AUDIT")
    print("inserted_nodes=" + ", ".join(sorted(inserted)))
    print("legacy_private_commands=preserved_unavailable")
    print("runtime_mutation=NONE")


if __name__ == "__main__":
    main()
