#!/usr/bin/env python3
import argparse
import json
import re
from pathlib import Path

EXPECTED = {
    ("GET", "api/v1/dashboard"),
    ("GET", "api/v1/accounts"),
    ("DELETE", "api/v1/transaction"),
    ("GET", "api/v1/transaction-reference"),
    ("GET", "api/v1/transactions"),
    ("GET", "api/v1/accounts-explorer-summary"),
}

INTERESTING_CODE = re.compile(r"(respond|format|valid|verify|normalize|request)", re.I)


def compact(value, limit=900):
    if value is None:
        return ""
    text = str(value).replace("\r", " ").replace("\n", " ")
    text = re.sub(r"\s+", " ", text).strip()
    return text[:limit]


def method_of(node):
    params = node.get("parameters") or {}
    return str(params.get("httpMethod") or "GET").upper()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    args = ap.parse_args()

    seen = []
    print("=== API-2B CONTRACT PREFLIGHT ===")

    for raw in args.files:
        path = Path(raw)
        wf = json.load(open(path, encoding="utf-8"))
        print()
        print(f"WORKFLOW {wf.get('id')} | {wf.get('name')}")
        print(
            "identity "
            f"active={wf.get('active')} "
            f"versionId={wf.get('versionId')} "
            f"activeVersionId={wf.get('activeVersionId')} "
            f"versionCounter={wf.get('versionCounter')}"
        )
        if wf.get("active") is not True or wf.get("versionId") != wf.get("activeVersionId"):
            raise SystemExit(f"identity gate failed for {wf.get('id')}")

        for node in wf.get("nodes", []):
            ntype = node.get("type", "")
            name = node.get("name", "")
            params = node.get("parameters") or {}

            if ntype == "n8n-nodes-base.webhook":
                method = method_of(node)
                endpoint = str(params.get("path") or "").lstrip("/")
                print(
                    f"WEBHOOK method={method} path=/{endpoint} "
                    f"name={name!r} authentication={params.get('authentication', 'none')} "
                    f"responseMode={params.get('responseMode')}"
                )
                key = (method, endpoint)
                if key in EXPECTED:
                    seen.append((key, wf.get("id"), name))

            if ntype == "n8n-nodes-base.respondToWebhook":
                response_code = (params.get("options") or {}).get("responseCode", 200)
                print(
                    f"RESPOND name={name!r} "
                    f"responseCode={compact(response_code)!r} "
                    f"respondWith={params.get('respondWith')!r} "
                    f"responseBody={compact(params.get('responseBody'))!r}"
                )

            if ntype == "n8n-nodes-base.code" and INTERESTING_CODE.search(name):
                print(
                    f"CODE name={name!r} "
                    f"js={compact(params.get('jsCode'))!r}"
                )

            if ntype == "n8n-nodes-base.postgres":
                query = str(params.get("query") or "")
                if re.search(r"moneytrack\.[A-Za-z_][A-Za-z0-9_]*_v1\s*\(", query, re.I):
                    cls = "BACKEND_BOUNDARY"
                elif re.search(r"\bselect\b", query, re.I) and "moneytrack." in query:
                    cls = "DIRECT_READ_SQL"
                else:
                    cls = "OTHER"
                print(
                    f"POSTGRES name={name!r} class={cls} query={compact(query, 500)!r}"
                )

    counts = {}
    for key, workflow_id, node_name in seen:
        counts.setdefault(key, []).append((workflow_id, node_name))

    print()
    print("=== RETAINED ENDPOINT OWNERSHIP ===")
    for key in sorted(EXPECTED):
        owners = counts.get(key, [])
        print(f"{key[0]} /{key[1]} owners={owners}")
        if len(owners) != 1:
            raise SystemExit(f"endpoint ownership gate failed for {key}: {owners}")

    print("retained_endpoint_ownership=PASS")
    print("active_identity_gate=PASS")
    print("API-2B contract preflight parser PASS")


if __name__ == "__main__":
    main()
