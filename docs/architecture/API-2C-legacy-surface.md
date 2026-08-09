# API-2C — Legacy Surface Decision

## Status

CURRENT — dispositions frozen; bounded removal pending

## Base

API-2B is closed and merged. The six retained MiniApp endpoints have canonical transport envelopes and the live read paths are behind backend/read-model boundaries.

API-2C is intentionally small. It decides the fate of only three non-retained HTTP surfaces identified by API-1.

## Production preflight evidence

The read-only production preflight completed against active/version-consistent workflows with n8n health PASS and global active direct business writers still `0`.

Observed active ownership:

| Method | Path | Workflow | Active version |
|---|---|---|---|
| GET | `/api/v1/me` | `7TJ2xQTxLsTydXZc` | `479` |
| GET | `/api/v1/i18n` | `7TJ2xQTxLsTydXZc` | `479` |
| POST | `/moneytrack-test` | `DER2Lc3dT2afyQhy` | `4004` |

### Access-log evidence

- `/api/v1/i18n`: real production use is confirmed. The retained nginx window contains requests to `/webhook/api/v1/i18n` with referrer `https://app.moneytrackapp.xyz/`. It must not be removed in API-2C.
- `/moneytrack-test`: `0` hits in the available 15 nginx access-log files. No supported repository consumer was identified. This remains a test-named ingress directly into the large Telegram orchestration workflow.
- `/api/v1/me`: the coarse substring preflight reported `2` matches, but inspection shows one is unrelated Grafana `/api/v1/metadata`, while the remaining line is `GET /api/v1/me` returning `401`, not the n8n production path `/webhook/api/v1/me`. Therefore current n8n consumer use is not proven. Because absence of proof is not enough to guarantee no external/future consumer, API-2C deprecates rather than removes it.

Repository search matches for all three strings are primarily workflow-provider definitions and therefore are not treated as caller evidence.

## Frozen dispositions

| Method | Path | Disposition | Reason |
|---|---|---|---|
| GET | `/api/v1/i18n` | `KEEP` | confirmed production requests from `app.moneytrackapp.xyz` |
| GET | `/api/v1/me` | `DEPRECATE` | no confirmed current n8n caller, but removal confidence is insufficient |
| POST | `/moneytrack-test` | `REMOVE` | no access-log hits, no supported consumer, test ingress unnecessarily expands production surface |

These dispositions are final for API-2C. API-3 must include the retained `/i18n` endpoint in centralized auth hardening. `/me` remains active but deprecated until a later explicit removal decision or consumer migration proves safe.

## Bounded removal scope

Only `POST /moneytrack-test` is removed in API-2C.

Production workflow:

- ID: `DER2Lc3dT2afyQhy`
- name: `MoneyTrack`
- pre-removal version: `4004`

Removal is limited to:

1. node `Webhook moneytrack-test` (`n8n-nodes-base.webhook`, node id `e14a05c6-061d-4bf2-99c2-08f63bb07980`);
2. connection source key `Webhook moneytrack-test` whose only downstream edge is `Normalize Webhook Input`.

No downstream node is removed. `Normalize Webhook Input` and all Telegram/update execution paths remain intact.

## Removal invariants

Candidate and production verification must prove:

- workflow ID/name unchanged;
- exactly one node removed: `Webhook moneytrack-test`;
- exactly one connection source key removed: `Webhook moneytrack-test`;
- no other node content changes;
- no other connection changes;
- all remaining webhook method/path signatures unchanged;
- `/api/v1/me` remains active;
- `/api/v1/i18n` remains active;
- retained six API endpoints are untouched;
- global direct business writers remain `0`;
- n8n health PASS;
- active `versionId == activeVersionId` after update.

The production update uses the same API-safe workflow settings allowlist established in API-2A/API-2B and keeps a pre-cutover rollback payload.

## Goal

Assign exactly one disposition to each surface:

- `KEEP` — proven live/contractual consumer exists;
- `DEPRECATE` — use/removal confidence requires later migration or explicit retirement;
- `REMOVE` — no supported consumer/use evidence and keeping the ingress only expands production surface.

## Evidence hierarchy

Decision evidence, in order of strength:

1. current production reverse-proxy access logs for the exact paths;
2. repository callers in canonical/current UI refs;
3. active n8n endpoint ownership and graph topology;
4. workflow-level execution counts only as context — they are not endpoint-specific when a workflow has multiple triggers.

Absence of a repo caller alone is not sufficient to assert that an external consumer does not exist.

## Invariants

API-2C must not:

- change retained six endpoint contracts;
- change backend/domain functions;
- change Telegram command/update ingress;
- change business writes;
- reopen API-2A or API-2B;
- introduce auth changes reserved for API-3.

## Gate

API-2C closes when:

- dispositions above are documented;
- `moneytrack-test` bounded candidate verification PASS;
- production removal PASS;
- `/moneytrack-test` is absent from active webhook ownership;
- `/api/v1/i18n` and `/api/v1/me` remain present;
- global direct business writers = `0`;
- n8n health PASS;
- evidence is merged to `main`.

## Next

After API-2C closes:

- API-3 — centralized Telegram InitData/auth/ownership/idempotency hardening;
- API-4 — final API integration gate.
