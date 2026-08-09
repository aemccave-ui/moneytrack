# API-2C — Legacy Surface Decision

## Status

CURRENT

## Base

API-2B is closed and merged. The six retained MiniApp endpoints now have canonical transport envelopes and the live read paths are behind backend/read-model boundaries.

API-2C is intentionally small. It decides the fate of only three non-retained HTTP surfaces identified by API-1:

| Method | Path | Workflow | Current status |
|---|---|---|---|
| GET | `/api/v1/me` | `7TJ2xQTxLsTydXZc` | no current MiniApp helper consumer found in API-1; direct read SQL |
| GET | `/api/v1/i18n` | `7TJ2xQTxLsTydXZc` | no current MiniApp helper consumer found in API-1; direct read SQL |
| POST | `/moneytrack-test` | `DER2Lc3dT2afyQhy` | test ingress on the large Telegram orchestration workflow; no MiniApp consumer found |

## Goal

Assign exactly one disposition to each surface:

- `KEEP` — proven live/contractual consumer exists;
- `DEPRECATE` — use exists but migration/removal must be scheduled;
- `REMOVE` — no supported consumer/use evidence and keeping the ingress only expands production surface.

API-2C does not refactor these endpoints. If removal is selected, the implementation must be a bounded workflow cleanup with structural verification and rollback.

## Evidence hierarchy

Decision evidence, in order of strength:

1. current production reverse-proxy access logs for the exact paths;
2. repository callers in canonical/current UI refs;
3. active n8n endpoint ownership and graph topology;
4. workflow-level execution counts only as context — they are not endpoint-specific when a workflow has multiple triggers.

Absence of a repo caller alone is not sufficient to assert that an external consumer does not exist.

## Read-only preflight gate

The API-2C preflight must report:

- exact active owner for each of the three paths;
- active/version-consistent workflow identity;
- exact webhook node and immediate downstream chain;
- repository caller matches in relevant refs;
- reverse-proxy access-log hit counts and latest retained log lines for each path where logs are available;
- workflow execution context for the last 30 days, clearly labelled as non-endpoint-specific;
- global direct business writers remain `0`;
- n8n health PASS.

## Decision rule

For each path:

- any confirmed current caller/access-log use => do not remove blindly; classify `KEEP` or `DEPRECATE` with the consumer recorded;
- no repo caller + no access-log hits in the available retained log window => candidate `REMOVE`;
- unavailable/insufficient access logs => do not infer zero external use; classify `DEPRECATE` unless another authoritative source proves non-use.

`/moneytrack-test` has a stronger removal bias because it exposes the large Telegram orchestration workflow through a test-named HTTP ingress.

## Invariants

API-2C must not:

- change retained six endpoint contracts;
- change backend/domain functions;
- change Telegram command/update ingress;
- change business writes;
- reopen API-2A or API-2B;
- introduce auth changes reserved for API-3.

## Next

After dispositions are frozen and any selected bounded removals are completed:

- API-3 — centralized Telegram InitData/auth/ownership/idempotency hardening;
- API-4 — final API integration gate.
