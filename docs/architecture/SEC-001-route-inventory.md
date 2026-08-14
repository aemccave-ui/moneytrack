# SEC-001 — Route / ingress authentication inventory

Status: SOURCE FORENSIC

Base commit: `3c6aa242f249fda7f5c8a75fad3cbef2f3aa98b3`

This inventory classifies the currently visible source surface for the SEC-001 application-lock cutover. It is deliberately based on actual consumers/workflows rather than route naming.

## Authentication classes

### Class A — MiniApp pre-unlock

Telegram MiniApp InitData authentication only. These are SEC-001 additions and must expose no private finance state.

Planned minimal surface:

- security status/bootstrap;
- initial PIN setup while protection is OFF;
- PIN unlock;
- biometric unlock.

Security-management actions performed after protection is enabled (change PIN, disable protection, biometric enrollment/revocation) are not Class A; they require an already valid MoneyTrack unlock session.

### Class B — MiniApp protected

Current MiniApp consumers observed in `miniapp/src/api.js` and the UX-023 receipt exception are protected when MoneyTrack protection is enabled.

| Method | Path / consumer | Disposition |
|---|---|---|
| GET | `/api/v1/dashboard` | Class B |
| GET | `/api/v1/accounts` | Class B |
| GET | `/api/v1/accounts/archived` | Class B |
| GET | `/api/v1/transaction-reference` | Class B |
| GET | `/api/v1/receipt?transaction_id=...` | Class B |
| PATCH | `/api/v1/receipt/accounting` | Class B; current direct-fetch exception must use canonical protected client path |
| PATCH | `/api/v1/receipt-item/category` | Class B |
| PATCH | `/api/v1/categories` | Class B |
| DELETE | `/api/v1/transaction` | Class B |
| POST | `/api/v1/transaction` | Class B |
| PATCH | `/api/v1/transaction` | Class B |
| GET | `/api/v1/transfer` | Class B |
| POST | `/api/v1/transfer` | Class B |
| PATCH | `/api/v1/transfer` | Class B |
| DELETE | `/api/v1/transfer` | Class B |
| POST | `/api/v1/transaction/text` | **Class B MiniApp text quick input** |
| POST | `/api/v1/transaction/photo` | **Class B MiniApp receipt-photo quick input** |
| POST | `/api/v1/transaction/voice` | **Class B MiniApp voice quick input** |
| GET | `/api/v1/transactions` | Class B |
| GET | `/api/v1/accounts-explorer-summary` | Class B |
| GET | `/api/v1/filter-presets` | Class B |
| POST | `/api/v1/filter-presets` | Class B |
| PATCH | `/api/v1/filter-presets` | Class B |
| DELETE | `/api/v1/filter-presets` | Class B |
| POST | `/api/v1/accounts` | Class B |
| PATCH | `/api/v1/accounts` | Class B |
| DELETE | `/api/v1/accounts` | Class B |
| POST | `/api/v1/accounts/copy` | Class B |
| POST | `/api/v1/accounts/move` | Class B |
| POST | `/api/v1/accounts/archive` | Class B |
| POST | `/api/v1/accounts/restore` | Class B |
| POST | `/api/v1/accounts/move-operations/preview` | Class B |
| POST | `/api/v1/accounts/move-operations` | Class B |

The list above is a source-consumer inventory, not proof that every corresponding runtime webhook is currently registered. Runtime workflow inventory remains mandatory before apply.

Unknown MiniApp routes fail closed.

## MiniApp boot finding

`App.jsx` currently calls `getDashboard()` and `getAccounts()` immediately on mount. `getAccountsExplorerSummary()` follows after dashboard/account data is available.

Therefore the accepted SEC-001 frontend shape is a top-level security gate above the protected application mount:

```text
Telegram WebApp initialize
        |
        v
Class A security bootstrap
        |
        +-- protection OFF --> mount protected application
        |
        +-- protection ON --> lock UI only
                              |
                              v
                         successful unlock
                              |
                              v
                    mount protected application
```

The existing protected application must not be mounted merely to hide it with CSS. This prevents current dashboard/account effects and settings/quick-input portals from starting before unlock.

## Canonical MiniApp client finding

`miniapp/src/api.js` has one shared `request()` helper that currently sends `X-Telegram-Init-Data`.

This is the primary source point for the second MiniApp authorization credential. The eventual protected request contract is:

```text
X-Telegram-Init-Data: <Telegram initData>
X-MoneyTrack-Unlock-Token: <memory-only MoneyTrack session token>
```

The second header is required only when protection is enabled and the route is Class B. Telegram InitData remains mandatory in all MiniApp classes.

`miniapp/src/receipt-accounting-api.js` currently bypasses the shared helper with direct `fetch()`. It is explicitly inventoried as an exception that must be removed/unified before the SEC-001 source gate can pass.

## Class C — Telegram Bot trusted quick capture

The source contains a separate Telegram Trigger in the main `MoneyTrack` workflow. This is a distinct ingress from the MiniApp HTTP API.

Target Class C is intentionally narrow:

- Telegram Bot text quick capture;
- Telegram Bot voice quick capture;
- Telegram Bot receipt-photo quick capture.

Class C keeps the existing Telegram Bot identity/trust boundary. A MoneyTrack unlock header is neither required nor accepted as a replacement for that boundary.

A shared PostgreSQL finance/receipt domain function does not merge Class B and Class C authentication semantics.

## Legacy Telegram Bot surface

The current Bot workflow also contains commands that disclose or manipulate finance state. These are not part of Class C target architecture.

Confirmed sensitive legacy reads include:

- `/summary`;
- `/last`;
- `/rep_budget`;
- `/rep_networth`.

`/settings` and budget/account/control command paths are also present in the legacy Bot command switch and must be included in the production-removal inventory according to their actual read/write behavior.

Disposition for all non-quick-capture Bot commands:

**LEGACY / REMOVE BEFORE SEC-001 PROD CUTOVER**

No fourth authentication class will be introduced to preserve them.

## Production Bot gate

Production cutover fails unless all of the following are proven:

```text
BOT_QUICK_CAPTURE_TEXT=PASS
BOT_QUICK_CAPTURE_VOICE=PASS
BOT_QUICK_CAPTURE_RECEIPT=PASS
BOT_INGRESS_WITHOUT_VALID_BOT_TRUST=REJECT
BOT_UNLOCK_TOKEN_WITHOUT_BOT_TRUST=REJECT
BOT_LEGACY_SENSITIVE_READS_REACHABLE=0
BOT_LEGACY_SENSITIVE_WRITES_REACHABLE=0
```

## Server authorization invariant

For every Class B MiniApp request when protection is enabled:

1. validate canonical Telegram InitData (`api3b-v1` contract preserved);
2. resolve verified Telegram/MoneyTrack identity;
3. validate MoneyTrack unlock session;
4. require session identity to match the Telegram identity;
5. only then execute the backend read/write boundary.

When protection is OFF, the second gate may permit the existing Telegram-authenticated behavior, but Telegram authentication is never removed or weakened.

## Current forensic gate

- MiniApp central client identified: PASS.
- immediate private boot fetch identified: PASS.
- direct-fetch protected exception identified: PASS.
- separate Bot ingress identified: PASS.
- Bot quick-capture vs legacy sensitive command distinction recorded: PASS.
- full runtime n8n endpoint inventory: PENDING runtime forensic.
- DB security schema apply: NOT STARTED.
- protected-route verifier implementation: NOT STARTED.
- frontend lock implementation: NOT STARTED.
- production legacy Bot removal: NOT STARTED / PROD GATE.
