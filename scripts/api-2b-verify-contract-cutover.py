#!/usr/bin/env python3
import argparse
import copy
import json
from pathlib import Path

POSTGRES = "n8n-nodes-base.postgres"
WEBHOOK = "n8n-nodes-base.webhook"
CODE = "n8n-nodes-base.code"
RESPOND = "n8n-nodes-base.respondToWebhook"


def load(path):
    return json.load(open(path, encoding="utf-8"))


def nodes_by_name(wf):
    return {n["name"]: n for n in wf.get("nodes", [])}


def hook_signature(wf):
    result = []
    for n in wf.get("nodes", []):
        if n.get("type") != WEBHOOK:
            continue
        p = n.get("parameters") or {}
        result.append((n.get("name"), str(p.get("httpMethod") or "GET").upper(), p.get("path")))
    return sorted(result)


def outgoing_names(wf, source_name):
    conn = (wf.get("connections") or {}).get(source_name) or {}
    result = []
    for lane in conn.get("main") or []:
        for edge in lane or []:
            if edge.get("node"):
                result.append(edge["node"])
    return result


def direct_responder_name(wf, source_name):
    by_name = nodes_by_name(wf)
    matches = [name for name in outgoing_names(wf, source_name) if by_name[name].get("type") == RESPOND]
    if len(matches) != 1:
        raise SystemExit(f"{wf.get('id')}: expected one responder after {source_name}, got {matches}")
    return matches[0]


def expected_changed(label, before):
    if label == "miniapp":
        return {
            "Format Dashboard Response",
            direct_responder_name(before, "Format Dashboard Response"),
            "Format Accounts Response",
            direct_responder_name(before, "Format Accounts Response"),
        }
    if label == "delete":
        return {"Format Delete Response", direct_responder_name(before, "Format Delete Response")}
    if label == "reference":
        return {"Format Transaction Reference", direct_responder_name(before, "Format Transaction Reference")}
    if label == "transactions":
        return {"Respond Transactions", "Respond Transactions Error"}
    if label == "summary":
        return {"Respond Explorer Summary", "Respond Explorer Summary Error"}
    raise SystemExit(f"unknown label {label}")


def changed_nodes(before, after):
    b = nodes_by_name(before)
    a = nodes_by_name(after)
    if set(b) != set(a):
        raise SystemExit(f"{before.get('id')}: node-name set changed")
    return {name for name in b if b[name] != a[name]}


def strip_allowed(node, kind):
    x = copy.deepcopy(node)
    params = x.setdefault("parameters", {})
    if kind == "code":
        params.pop("jsCode", None)
    elif kind == "respond":
        params.pop("respondWith", None)
        params.pop("responseBody", None)
        options = params.get("options")
        if isinstance(options, dict):
            options.pop("responseCode", None)
            if not options:
                params["options"] = {}
    return x


def verify_canonical_markers(label, after):
    by_name = nodes_by_name(after)
    if label == "miniapp":
        formatters = ["Format Dashboard Response", "Format Accounts Response"]
    elif label == "delete":
        formatters = ["Format Delete Response"]
    elif label == "reference":
        formatters = ["Format Transaction Reference"]
    else:
        formatters = []

    for name in formatters:
        js = str((by_name[name].get("parameters") or {}).get("jsCode") or "")
        if "ok: true" not in js:
            raise SystemExit(f"{label}: {name} missing ok:true")
        if label in {"miniapp", "delete", "reference"} and "error: { code:" not in js:
            raise SystemExit(f"{label}: {name} missing canonical error.code")

    responders = [n for n in after.get("nodes", []) if n.get("name") in expected_changed(label, after) and n.get("type") == RESPOND]
    for n in responders:
        p = n.get("parameters") or {}
        if p.get("respondWith") != "json":
            raise SystemExit(f"{label}: {n.get('name')} respondWith != json")
        if "ok:" not in str(p.get("responseBody")) and "JSON.stringify($json)" not in str(p.get("responseBody")):
            raise SystemExit(f"{label}: {n.get('name')} response body not canonical/full-json")
        if "responseCode" not in (p.get("options") or {}):
            raise SystemExit(f"{label}: {n.get('name')} response code not configured")


def verify(label, before, after):
    if before.get("id") != after.get("id"):
        raise SystemExit(f"{label}: workflow id changed")
    if before.get("connections") != after.get("connections"):
        raise SystemExit(f"{label}: graph connections changed")
    if hook_signature(before) != hook_signature(after):
        raise SystemExit(f"{label}: webhook method/path changed")

    b = nodes_by_name(before)
    a = nodes_by_name(after)
    expected = expected_changed(label, before)
    changed = changed_nodes(before, after)
    if changed != expected:
        raise SystemExit(f"{label}: changed nodes mismatch expected={sorted(expected)} actual={sorted(changed)}")

    for name in b:
        if b[name].get("type") == POSTGRES and b[name] != a[name]:
            raise SystemExit(f"{label}: backend/Postgres node changed: {name}")
        if ("Verify Telegram InitData" in name or name in {"Validate Transactions Request", "Validate Explorer Summary Request"}) and b[name] != a[name]:
            raise SystemExit(f"{label}: auth/validation node changed: {name}")

    for name in expected:
        bnode = b[name]
        anode = a[name]
        if bnode.get("type") == CODE:
            if strip_allowed(bnode, "code") != strip_allowed(anode, "code"):
                raise SystemExit(f"{label}: non-jsCode field changed in {name}")
        elif bnode.get("type") == RESPOND:
            if strip_allowed(bnode, "respond") != strip_allowed(anode, "respond"):
                raise SystemExit(f"{label}: disallowed Respond field changed in {name}")
        else:
            raise SystemExit(f"{label}: unexpected changed node type for {name}: {bnode.get('type')}")

    verify_canonical_markers(label, after)
    print(f"{label}: graph/endpoints/backend/auth parity PASS; changed_nodes={sorted(changed)}; canonical_contract=PASS")


def main():
    ap = argparse.ArgumentParser()
    for label in ("miniapp", "delete", "reference", "transactions", "summary"):
        ap.add_argument(f"--{label}-before", required=True)
        ap.add_argument(f"--{label}-after", required=True)
    args = ap.parse_args()

    for label in ("miniapp", "delete", "reference", "transactions", "summary"):
        verify(label, load(getattr(args, f"{label}_before")), load(getattr(args, f"{label}_after")))
    print("API-2B structural contract verifier PASS")


if __name__ == "__main__":
    main()
