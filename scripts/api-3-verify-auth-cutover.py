#!/usr/bin/env python3
import argparse
import copy
import json
from pathlib import Path

CODE = "n8n-nodes-base.code"
POSTGRES = "n8n-nodes-base.postgres"
WEBHOOK = "n8n-nodes-base.webhook"
IF = "n8n-nodes-base.if"
RESPOND = "n8n-nodes-base.respondToWebhook"

STANDALONE = {
    "miniapp": [
        "Verify Telegram InitData me",
        "Verify Telegram InitData dashboard",
        "Verify Telegram InitData accounts",
        "Verify Telegram InitData i18n",
    ],
    "delete": ["Verify Telegram InitData delete"],
    "reference": ["Verify Telegram InitData reference"],
}

COMBINED = {
    "transactions": "Validate Transactions Request",
    "summary": "Validate Explorer Summary Request",
}


def load(path):
    return json.load(open(path, encoding="utf-8"))


def nodes_by_name(wf):
    return {n["name"]: n for n in wf.get("nodes", [])}


def main_edges(wf, source):
    return copy.deepcopy(((wf.get("connections") or {}).get(source) or {}).get("main") or [])


def hook_signature(wf):
    result = []
    for node in wf.get("nodes", []):
        if node.get("type") != WEBHOOK:
            continue
        p = node.get("parameters") or {}
        result.append(
            (
                node.get("name"),
                str(p.get("httpMethod") or "GET").upper(),
                str(p.get("path") or "").lstrip("/"),
            )
        )
    return sorted(result)


def strip_js(node):
    x = copy.deepcopy(node)
    x.setdefault("parameters", {}).pop("jsCode", None)
    return x


def canonical_code_gate(js, fragment):
    required = [
        fragment,
        "api3b-v1",
        "moneytrackVerifyTelegramInitData",
        "AUTH_DATE_EXPIRED",
        "AUTH_DATE_IN_FUTURE",
        "timingSafeEqual",
        "Date.now()",
        "MONEYTRACK_INIT_DATA_MAX_AGE_SECONDS",
        "MONEYTRACK_INIT_DATA_MAX_FUTURE_SKEW_SECONDS",
    ]
    for marker in required:
        if marker not in js:
            raise SystemExit(f"canonical auth marker missing: {marker[:80]!r}")
    if "throw new Error" in js:
        raise SystemExit("canonical auth node still contains throw new Error")


def verify_common(label, before, after):
    if before.get("id") != after.get("id") or before.get("name") != after.get("name"):
        raise SystemExit(f"{label}: workflow identity changed")
    if hook_signature(before) != hook_signature(after):
        raise SystemExit(f"{label}: webhook method/path signature changed")

    b = nodes_by_name(before)
    a = nodes_by_name(after)
    for name, bnode in b.items():
        if bnode.get("type") == POSTGRES:
            if name not in a or bnode != a[name]:
                raise SystemExit(f"{label}: backend/Postgres node changed: {name}")


def verify_standalone(label, before, after, fragment):
    verify_common(label, before, after)
    b = nodes_by_name(before)
    a = nodes_by_name(after)
    auth_names = STANDALONE[label]
    responder = "Respond Auth Error"
    expected_added = {responder}
    for auth_name in auth_names:
        suffix = auth_name.replace("Verify Telegram InitData ", "")
        expected_added.add(f"Auth Valid? {suffix}")

    actual_added = set(a) - set(b)
    if actual_added != expected_added:
        raise SystemExit(
            f"{label}: added node mismatch expected={sorted(expected_added)} actual={sorted(actual_added)}"
        )
    if set(b) - set(a):
        raise SystemExit(f"{label}: original node removed: {sorted(set(b)-set(a))}")

    for name in b:
        if name in auth_names:
            if strip_js(b[name]) != strip_js(a[name]):
                raise SystemExit(f"{label}: non-js field changed in auth node {name}")
            js = str((a[name].get("parameters") or {}).get("jsCode") or "")
            canonical_code_gate(js, fragment)
            if "auth_ok: true" not in js or "auth_ok: false" not in js:
                raise SystemExit(f"{label}: handled auth result markers missing in {name}")
        elif b[name] != a[name]:
            raise SystemExit(f"{label}: unexpected original node change: {name}")

    rnode = a[responder]
    if rnode.get("type") != RESPOND:
        raise SystemExit(f"{label}: auth responder has wrong node type")
    rp = rnode.get("parameters") or {}
    if rp.get("respondWith") != "json":
        raise SystemExit(f"{label}: auth responder respondWith != json")
    if "error" not in str(rp.get("responseBody")) or "code" not in str(rp.get("responseBody")):
        raise SystemExit(f"{label}: auth responder body not canonical")
    if "responseCode" not in (rp.get("options") or {}):
        raise SystemExit(f"{label}: auth responder response code missing")

    bconn = before.get("connections") or {}
    aconn = after.get("connections") or {}

    for source, value in bconn.items():
        if source in auth_names:
            continue
        if value != aconn.get(source):
            raise SystemExit(f"{label}: unexpected existing connection change at {source}")

    allowed_new_sources = set()
    for auth_name in auth_names:
        original = main_edges(before, auth_name)
        if len(original) != 1 or not original[0]:
            raise SystemExit(f"{label}: invalid before auth outgoing shape at {auth_name}: {original}")
        gate = f"Auth Valid? {auth_name.replace('Verify Telegram InitData ', '')}"
        allowed_new_sources.add(gate)
        expected_auth = {"main": [[{"node": gate, "type": "main", "index": 0}]]}
        if aconn.get(auth_name) != expected_auth:
            raise SystemExit(f"{label}: auth source not rerouted exactly to {gate}")
        expected_gate = {
            "main": [
                original[0],
                [{"node": responder, "type": "main", "index": 0}],
            ]
        }
        if aconn.get(gate) != expected_gate:
            raise SystemExit(f"{label}: gate branch mismatch at {gate}")
        if a[gate].get("type") != IF:
            raise SystemExit(f"{label}: {gate} is not IF")
        gp = a[gate].get("parameters") or {}
        if "$json.auth_ok === true" not in json.dumps(gp):
            raise SystemExit(f"{label}: {gate} does not gate auth_ok")

    unexpected_connection_sources = set(aconn) - set(bconn) - allowed_new_sources
    if unexpected_connection_sources:
        raise SystemExit(
            f"{label}: unexpected new connection sources: {sorted(unexpected_connection_sources)}"
        )

    print(
        f"{label}: standalone auth isolation PASS; added_nodes={sorted(expected_added)}; "
        f"canonical_auth=PASS"
    )


def split_combined(js):
    start = js.find("const initData =")
    success = js.rfind("return [{")
    if start == -1 or success == -1 or success <= start:
        raise SystemExit("combined validator split points not found")
    return js[:start], js[success:]


def verify_combined(label, before, after, fragment):
    verify_common(label, before, after)
    b = nodes_by_name(before)
    a = nodes_by_name(after)
    if set(b) != set(a):
        raise SystemExit(f"{label}: node set changed")
    if before.get("connections") != after.get("connections"):
        raise SystemExit(f"{label}: graph connections changed")

    target = COMBINED[label]
    changed = {name for name in b if b[name] != a[name]}
    if changed != {target}:
        raise SystemExit(f"{label}: changed nodes mismatch: {sorted(changed)}")
    if strip_js(b[target]) != strip_js(a[target]):
        raise SystemExit(f"{label}: non-js field changed in {target}")

    before_js = str((b[target].get("parameters") or {}).get("jsCode") or "")
    after_js = str((a[target].get("parameters") or {}).get("jsCode") or "")
    canonical_code_gate(after_js, fragment)
    if "return fail(auth.http_status, auth.error.code)" not in after_js:
        raise SystemExit(f"{label}: canonical auth failure not mapped into existing handled error branch")

    before_prefix, before_suffix = split_combined(before_js)
    injected = "\n\n" + fragment
    if injected not in after_js:
        raise SystemExit(f"{label}: exact canonical fragment injection boundary missing")
    after_without_fragment = after_js.replace(injected, "", 1)
    after_prefix, after_suffix = split_combined(after_without_fragment)
    if before_prefix != after_prefix:
        raise SystemExit(f"{label}: request-validation prefix changed")
    if before_suffix != after_suffix:
        raise SystemExit(f"{label}: successful request output suffix changed")

    print(
        f"{label}: combined validator isolation PASS; request_validation=UNCHANGED; "
        f"graph=UNCHANGED; canonical_auth=PASS"
    )


def main():
    ap = argparse.ArgumentParser()
    for label in ("miniapp", "delete", "reference", "transactions", "summary"):
        ap.add_argument(f"--{label}-before", required=True)
        ap.add_argument(f"--{label}-after", required=True)
    ap.add_argument("--fragment", default="scripts/api-3-telegram-initdata-verifier.fragment.js")
    args = ap.parse_args()

    fragment = Path(args.fragment).read_text(encoding="utf-8").strip()
    for label in ("miniapp", "delete", "reference", "transactions", "summary"):
        before = load(getattr(args, f"{label}_before"))
        after = load(getattr(args, f"{label}_after"))
        if label in STANDALONE:
            verify_standalone(label, before, after, fragment)
        else:
            verify_combined(label, before, after, fragment)

    print("API-3B structural auth verifier PASS")


if __name__ == "__main__":
    main()
