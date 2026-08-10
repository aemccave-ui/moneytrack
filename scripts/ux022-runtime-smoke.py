#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import date


def api(base: str, init_data: str, path: str, method: str = "GET", body: dict | None = None) -> dict:
    data = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(
        f"{base.rstrip('/')}/{path.lstrip('/')}",
        method=method,
        data=data,
        headers={
            "Accept": "application/json",
            "Content-Type": "application/json",
            "X-Telegram-Init-Data": init_data,
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            text = response.read().decode("utf-8")
            status = response.status
    except urllib.error.HTTPError as error:
        text = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"{method} {path} HTTP {error.code}: {text[:500]}") from error
    if status < 200 or status >= 300:
        raise RuntimeError(f"{method} {path} HTTP {status}: {text[:500]}")
    payload = json.loads(text or "{}")
    if payload.get("ok") is False:
        raise RuntimeError(f"{method} {path}: {payload}")
    return payload.get("data", payload)


def first_list(payload: dict, *keys: str) -> list:
    for key in keys:
        value = payload.get(key)
        if isinstance(value, list):
            return value
    return []


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="https://n8n.moneytrackapp.xyz/webhook")
    parser.add_argument("--init-data", required=True)
    args = parser.parse_args()

    created_ids: list[int] = []
    preset_id: int | None = None
    archived_id: int | None = None
    try:
        accounts_payload = api(args.base, args.init_data, "api/v1/accounts")
        accounts = first_list(accounts_payload, "accounts", "items")
        reference = api(args.base, args.init_data, "api/v1/transaction-reference")
        currencies = first_list(reference, "currencies")
        currency = None
        if accounts:
            currency = accounts[0].get("currency_code")
        if not currency and currencies:
            currency = currencies[0].get("code")
        if not currency:
            raise RuntimeError("No active currency available for lifecycle smoke")

        stamp = date.today().strftime("%Y%m%d")
        a = api(args.base, args.init_data, "api/v1/accounts", "POST", {
            "name": f"UX022 smoke {stamp}",
            "account_type": "cash",
            "currency_code": currency,
            "parent_id": None,
        })["account"]
        a_id = int(a["id"])
        created_ids.append(a_id)

        b = api(args.base, args.init_data, "api/v1/accounts/copy", "POST", {"account_id": a_id})["account"]
        b_id = int(b["id"])
        created_ids.append(b_id)

        api(args.base, args.init_data, "api/v1/accounts/move", "POST", {"account_id": b_id, "parent_id": a_id})
        api(args.base, args.init_data, "api/v1/accounts/move", "POST", {"account_id": b_id, "parent_id": None})

        preview = api(args.base, args.init_data, "api/v1/accounts/move-operations/preview", "POST", {
            "source_account_id": b_id,
            "target_account_id": a_id,
        })
        if int(preview.get("operation_count", -1)) != 0 or int(preview.get("transfer_count", -1)) != 0:
            raise RuntimeError(f"Unexpected history on fresh copied account: {preview}")
        api(args.base, args.init_data, "api/v1/accounts/move-operations", "POST", {
            "source_account_id": b_id,
            "target_account_id": a_id,
        })

        api(args.base, args.init_data, "api/v1/accounts/archive", "POST", {"account_id": b_id})
        archived_id = b_id
        archived = api(args.base, args.init_data, "api/v1/accounts/archived")
        archived_accounts = first_list(archived, "accounts", "items")
        if not any(int(item.get("id", -1)) == b_id for item in archived_accounts):
            raise RuntimeError("Archived account missing from archived read model")
        api(args.base, args.init_data, "api/v1/accounts/restore", "POST", {"account_id": b_id})
        archived_id = None

        account_ids = [int(item["id"]) for item in accounts if str(item.get("id", "")).isdigit()]
        account_ids.extend([a_id, b_id])
        preset = api(args.base, args.init_data, "api/v1/filter-presets", "POST", {
            "name": f"UX022 smoke {stamp}",
            "account_ids": sorted(set(account_ids)),
            "income_category_ids": [],
            "expense_category_ids": [],
        })["preset"]
        preset_id = int(preset["id"])
        renamed = api(args.base, args.init_data, "api/v1/filter-presets", "PATCH", {
            "id": preset_id,
            "name": f"UX022 smoke renamed {stamp}",
        })["preset"]
        if int(renamed["id"]) != preset_id:
            raise RuntimeError("Preset rename returned wrong id")
        api(args.base, args.init_data, f"api/v1/filter-presets?id={preset_id}", "DELETE")
        preset_id = None

        today = date.today().isoformat()
        month_start = date.today().replace(day=1).isoformat()
        selected = ",".join(str(value) for value in sorted(set(account_ids)))
        summary_path = "api/v1/accounts-explorer-summary?" + urllib.parse.urlencode({
            "date_from": month_start,
            "date_to": today,
            "selected_account_ids": selected,
        })
        summary = api(args.base, args.init_data, summary_path)
        if not isinstance(summary.get("account_balances"), list):
            raise RuntimeError("Explorer summary has no account_balances array")
        if not str(summary.get("base_currency") or ""):
            raise RuntimeError("Explorer summary base_currency is empty")

        tx_path = "api/v1/transactions?" + urllib.parse.urlencode({
            "account_id": a_id,
            "date_from": month_start,
            "date_to": today,
            "include_descendants": "true",
            "selected_account_ids": f"{a_id},{b_id}",
        })
        tx = api(args.base, args.init_data, tx_path)
        if not isinstance(tx.get("transactions"), list):
            raise RuntimeError("Transactions read model has no transactions array")

        api(args.base, args.init_data, f"api/v1/accounts?id={b_id}", "DELETE")
        created_ids.remove(b_id)
        api(args.base, args.init_data, f"api/v1/accounts?id={a_id}", "DELETE")
        created_ids.remove(a_id)

        print("real_webhook_runtime_smoke=PASS")
        print("account_lifecycle_smoke=PASS")
        print("preset_lifecycle_smoke=PASS")
        print("explorer_contract_smoke=PASS")
    finally:
        if preset_id is not None:
            try:
                api(args.base, args.init_data, f"api/v1/filter-presets?id={preset_id}", "DELETE")
            except Exception as error:
                print(f"cleanup_preset=FAIL {error}", file=sys.stderr)
        if archived_id is not None:
            try:
                api(args.base, args.init_data, "api/v1/accounts/restore", "POST", {"account_id": archived_id})
            except Exception as error:
                print(f"cleanup_restore=FAIL {error}", file=sys.stderr)
        for account_id in reversed(created_ids):
            try:
                api(args.base, args.init_data, f"api/v1/accounts?id={account_id}", "DELETE")
            except Exception as error:
                print(f"cleanup_account_{account_id}=FAIL {error}", file=sys.stderr)


if __name__ == "__main__":
    main()
