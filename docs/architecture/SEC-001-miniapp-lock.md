# SEC-001 — MoneyTrack MiniApp App Lock

Status: SOURCE / FORENSIC IN PROGRESS

Base: `agent/ux-023-receipt-modal-impl` @ `3c6aa242f249fda7f5c8a75fad3cbef2f3aa98b3`

Working branch: `agent/sec001`.

> The intended branch name from the task is `agent/sec-001-miniapp-lock`. The GitHub connector safety layer rejects that literal ref name, so source work is isolated on `agent/sec001` from the exact required base SHA. UX-023 is not modified directly.

## Goal

Add a real MoneyTrack application lock on top of the existing canonical Telegram MiniApp InitData authentication.

Authentication layers remain independent:

1. Telegram MiniApp identity: canonical `api3b-v1` InitData verification.
2. MoneyTrack unlock: PIN or Telegram native biometrics, issuing a short-lived unlock session.

A frontend-only lock is forbidden. Protected MiniApp APIs must enforce the second gate server-side while protection is enabled.

## Ingress boundary

MoneyTrack has two distinct user interaction channels and they must not be conflated merely because they call the same finance-domain functions.

### Class A — MiniApp pre-unlock

Telegram MiniApp authentication only.

Allowed only for minimal security bootstrap/unlock operations:

- `GET /api/v1/security/status`
- initial PIN setup while protection is OFF
- PIN unlock
- biometric unlock

Security-management operations that change an already-enabled security state are not Class A.

### Class B — MiniApp protected

Telegram MiniApp authentication **plus** a valid MoneyTrack unlock session when protection is enabled.

Includes all financial/private reads and all MiniApp-originated writes, including:

- dashboard;
- accounts;
- transactions and transfers;
- receipts;
- budgets/statistics;
- settings/private references;
- category/account/filter-preset mutations;
- manual transaction creation;
- MiniApp text quick input;
- MiniApp voice quick input;
- MiniApp receipt-photo quick input;
- PIN change / protection disable / biometric enrollment and revocation.

When protection is OFF, these routes retain the existing Telegram-authenticated behavior.

Unknown MiniApp routes fail closed.

### Class C — Telegram Bot trusted quick-capture ingress

Existing Telegram Bot identity/authentication boundary only:

- text operation;
- voice operation;
- receipt photo.

These remain usable while the MiniApp itself is locked.

Class C:

- is not public/anonymous;
- does not require `X-MoneyTrack-Unlock-Token`;
- must not accept `X-MoneyTrack-Unlock-Token` as a substitute for the existing Bot trust boundary;
- may share domain write functions with Class B without sharing its authentication boundary;
- may return only minimal ingestion acknowledgement as part of the target architecture.

## Telegram Bot legacy disposition

Existing Telegram Bot command/report functionality outside quick capture is declared **LEGACY / REMOVE BEFORE PROD**.

Confirmed legacy sensitive reads include at least:

- `/summary`;
- `/last`;
- `/rep_budget`;
- `/rep_networth`.

Additional Bot read/write/admin commands discovered during inventory receive the same legacy disposition unless explicitly re-approved.

SEC-001 will not create a fourth authentication model to preserve these commands.

Production acceptance requires:

```text
BOT_QUICK_CAPTURE_TEXT=PASS
BOT_QUICK_CAPTURE_VOICE=PASS
BOT_QUICK_CAPTURE_RECEIPT=PASS
BOT_LEGACY_SENSITIVE_READS_REACHABLE=0
BOT_LEGACY_SENSITIVE_WRITES_REACHABLE=0
```

Removal is a production-cutover gate: simply documenting a command as legacy is insufficient if it can still disclose or mutate private financial state after the SEC-001 production cutover.

## Current client forensic

`miniapp/src/api.js` currently has one shared MiniApp `request()` helper. It sends `X-Telegram-Init-Data` and no MoneyTrack unlock credential.

MiniApp manual/text/photo/voice operations route through this client, so the second header can be added centrally without changing Telegram Bot ingress.

`miniapp/src/receipt-accounting-api.js` is currently a direct `fetch()` exception and must be brought under the same canonical MiniApp request/auth path.

`miniapp/src/App.jsx` currently requests dashboard/accounts immediately after mount. SEC-001 must gate mounting/loading of the protected application behind a minimal security bootstrap so private data is never fetched before unlock.

## Cryptographic source decision

Repository forensic found no existing pgcrypto/KDF convention to reuse. SEC-001 therefore must not assume a PostgreSQL crypto extension is installed.

Planned source contract:

- Node/n8n server-side `crypto` for random tokens, HMAC/hash, timing-safe comparisons and PIN KDF;
- PIN verifier computed server-side with a slow KDF plus `MONEYTRACK_PIN_PEPPER`;
- pepper never stored in PostgreSQL;
- PostgreSQL stores only verifier material and hashed opaque session/biometric tokens;
- no PIN, raw biometric token or raw unlock token in PostgreSQL or browser storage;
- unlock token remains in JavaScript memory only.

Runtime preflight must still inventory environment-secret handling and verify that required server-side crypto primitives are available before apply.

## Unlock session model

Use high-entropy opaque random unlock tokens rather than reusing Telegram InitData.

- raw token: returned once to the MiniApp and held in memory only;
- DB: token hash only;
- identity binding: MoneyTrack user / Telegram user;
- fixed short expiry: initial target 15 minutes;
- security version captured in the session;
- PIN change / protection disable revoke active sessions and increment security version;
- expired/revoked/mismatched sessions reject with a canonical lock error.

This deliberately avoids a fragile pseudo-sliding expiration implementation.

## Biometric model

Use only `Telegram.WebApp.BiometricManager`.

Enrollment is allowed only from an already-unlocked MiniApp session.

Backend creates at least 256 bits of random device credential material, stores only its hash bound to `user_id + device_id`, and returns the raw token once for `BiometricManager.updateBiometricToken()`.

Biometric unlock requires both valid Telegram InitData and a matching active device credential. PIN remains mandatory fallback.

## Mandatory ingress tests

Protection enabled:

1. locked MiniApp `GET dashboard` -> reject;
2. locked MiniApp create transaction -> reject;
3. locked MiniApp, Telegram Bot text quick capture -> accept / transaction created;
4. locked MiniApp, Telegram Bot voice quick capture -> accept / transaction created;
5. locked MiniApp, Telegram Bot receipt photo -> accept / transaction created;
6. unlock MiniApp -> newly created Bot operations visible;
7. Bot ingress without valid Bot trust context -> reject;
8. Bot ingress with an unlock token but without valid Bot trust context -> reject;
9. legacy sensitive Bot read/write commands reachable at production cutover -> fail gate.

## Delivery discipline

- no direct work on UX-023;
- no production mutation during source work;
- preview-only controlled apply after source gate;
- DB/workflow/frontend backups before mutation;
- fail closed on unknown MiniApp routes;
- do not merge until runtime + real Telegram acceptance passes.
