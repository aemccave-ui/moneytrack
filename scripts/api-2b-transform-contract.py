#!/usr/bin/env python3
import argparse
import copy
import json
import re
from pathlib import Path

FULL_JSON = "={{ JSON.stringify($json) }}"
ERROR_JSON = "={{ JSON.stringify({ ok: false, error: { code: typeof $json.error === 'string' ? $json.error : ($json.error?.code || 'INTERNAL_ERROR') } }) }}"
DYNAMIC_STATUS = "={{ $json.http_status || 200 }}"
ERROR_STATUS = "={{ $json.http_status || 500 }}"


def load(path):
    return json.load(open(path, encoding="utf-8"))


def dump(obj, path):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write("\n")


def node_by_name(wf, name):
    matches = [n for n in wf.get("nodes", []) if n.get("name") == name]
    if len(matches) != 1:
        raise SystemExit(f"expected exactly one node {name!r}, found {len(matches)} in {wf.get('id')}")
    return matches[0]


def outgoing_names(wf, source_name):
    conn = (wf.get("connections") or {}).get(source_name) or {}
    result = []
    for lane in conn.get("main") or []:
        for edge in lane or []:
            if edge.get("node"):
                result.append(edge["node"])
    return result


def direct_respond_node(wf, source_name):
    candidates = []
    for name in outgoing_names(wf, source_name):
        node = node_by_name(wf, name)
        if node.get("type") == "n8n-nodes-base.respondToWebhook":
            candidates.append(node)
    if len(candidates) != 1:
        raise SystemExit(
            f"expected exactly one direct Respond to Webhook after {source_name!r}, "
            f"found {[n.get('name') for n in candidates]}"
        )
    return candidates[0]


def set_respond(node, response_body, response_code):
    params = node.setdefault("parameters", {})
    params["respondWith"] = "json"
    params["responseBody"] = response_body
    options = params.setdefault("options", {})
    options["responseCode"] = response_code


def replace_user_not_found_return(js):
    pattern = re.compile(
        r'return\s*\[\{\s*json:\s*\{\s*error:\s*["\']USER_NOT_FOUND["\']\s*\}\s*\}\];'
    )
    replacement = (
        'return [{ json: { ok: false, http_status: 404, '
        'error: { code: "USER_NOT_FOUND" } } }];'
    )
    js2, count = pattern.subn(replacement, js, count=1)
    if count != 1:
        raise SystemExit("could not normalize USER_NOT_FOUND return")
    return js2


def add_ok_true_to_success(js):
    pattern = re.compile(r'return\s*\[\{\s*json:\s*\{\s*data\s*:')
    js2, count = pattern.subn('return [{ json: { ok: true, data:', js, count=1)
    if count != 1:
        raise SystemExit("could not add ok:true to success envelope")
    return js2


def normalize_simple_formatter(wf, format_name):
    node = node_by_name(wf, format_name)
    js = str((node.get("parameters") or {}).get("jsCode") or "")
    js = replace_user_not_found_return(js)
    js = add_ok_true_to_success(js)
    node["parameters"]["jsCode"] = js
    responder = direct_respond_node(wf, format_name)
    set_respond(responder, FULL_JSON, DYNAMIC_STATUS)
    return [format_name, responder["name"]]


def normalize_delete(wf):
    name = "Format Delete Response"
    node = node_by_name(wf, name)
    js = str((node.get("parameters") or {}).get("jsCode") or "")
    replacements = [
        (
            r'if\s*\(\s*!row\.user_found\s*\)\s*throw\s+new\s+Error\(["\']USER_NOT_FOUND["\']\)\s*;',
            'if (!row.user_found) return [{ json: { ok: false, http_status: 404, error: { code: "USER_NOT_FOUND" } } }];',
        ),
        (
            r'if\s*\(\s*!row\.deleted\s*\)\s*throw\s+new\s+Error\(["\']TRANSACTION_NOT_FOUND["\']\)\s*;',
            'if (!row.deleted) return [{ json: { ok: false, http_status: 404, error: { code: "TRANSACTION_NOT_FOUND" } } }];',
        ),
    ]
    for pattern, replacement in replacements:
        js, count = re.subn(pattern, replacement, js, count=1)
        if count != 1:
            raise SystemExit(f"could not normalize delete formatter pattern: {pattern}")
    js = add_ok_true_to_success(js)
    node["parameters"]["jsCode"] = js
    responder = direct_respond_node(wf, name)
    set_respond(responder, FULL_JSON, DYNAMIC_STATUS)
    return [name, responder["name"]]


def normalize_reference(wf):
    name = "Format Transaction Reference"
    node = node_by_name(wf, name)
    js = str((node.get("parameters") or {}).get("jsCode") or "")
    js, count = re.subn(
        r'if\s*\(\s*!row\.user_found\s*\)\s*throw\s+new\s+Error\(["\']USER_NOT_FOUND["\']\)\s*;',
        'if (!row.user_found) return [{ json: { ok: false, http_status: 404, error: { code: "USER_NOT_FOUND" } } }];',
        js,
        count=1,
    )
    if count != 1:
        raise SystemExit("could not normalize reference USER_NOT_FOUND")
    js = add_ok_true_to_success(js)
    node["parameters"]["jsCode"] = js
    responder = direct_respond_node(wf, name)
    set_respond(responder, FULL_JSON, DYNAMIC_STATUS)
    return [name, responder["name"]]


def normalize_split_responders(wf, success_name, error_name):
    success = node_by_name(wf, success_name)
    error = node_by_name(wf, error_name)
    set_respond(success, FULL_JSON, 200)
    set_respond(error, ERROR_JSON, ERROR_STATUS)
    return [success_name, error_name]


def assert_endpoint_identity(before, after):
    def hooks(wf):
        values = []
        for n in wf.get("nodes", []):
            if n.get("type") != "n8n-nodes-base.webhook":
                continue
            p = n.get("parameters") or {}
            values.append((n.get("name"), str(p.get("httpMethod") or "GET").upper(), p.get("path")))
        return sorted(values)
    if hooks(before) != hooks(after):
        raise SystemExit(f"webhook method/path drift in {before.get('id')}")


def transform(label, before):
    after = copy.deepcopy(before)
    if label == "miniapp":
        changed = []
        changed += normalize_simple_formatter(after, "Format Dashboard Response")
        changed += normalize_simple_formatter(after, "Format Accounts Response")
    elif label == "delete":
        changed = normalize_delete(after)
    elif label == "reference":
        changed = normalize_reference(after)
    elif label == "transactions":
        changed = normalize_split_responders(after, "Respond Transactions", "Respond Transactions Error")
    elif label == "summary":
        changed = normalize_split_responders(after, "Respond Explorer Summary", "Respond Explorer Summary Error")
    else:
        raise SystemExit(f"unknown label {label}")
    assert_endpoint_identity(before, after)
    return after, changed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--miniapp", required=True)
    ap.add_argument("--delete", required=True)
    ap.add_argument("--reference", required=True)
    ap.add_argument("--transactions", required=True)
    ap.add_argument("--summary", required=True)
    ap.add_argument("--out-dir", required=True)
    args = ap.parse_args()

    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)

    for label in ("miniapp", "delete", "reference", "transactions", "summary"):
        before = load(getattr(args, label))
        after, changed = transform(label, before)
        dump(after, out / f"{label}.candidate.json")
        print(f"{label}: changed_nodes={changed}")

    print("API-2B transform complete")


if __name__ == "__main__":
    main()
