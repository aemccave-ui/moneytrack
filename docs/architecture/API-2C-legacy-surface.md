# API-2C — Legacy Surface Decision

## Status

COMPLETE — production removal verified

## Base

API-2B is closed and merged. The six retained MiniApp endpoints have canonical transport envelopes and the live read paths are behind backend/read-model boundaries.

API-2C was intentionally limited to three non-retained HTTP surfaces identified by API-1.

## Frozen dispositions

| Method | Path | Disposition | Final result |
|---|---|---|---|
| GET | `/api/v1/i18n` | `KEEP` | remains active; production use confirmed |
| GET | `/api/v1/me` | `DEPRECATE` | remains active; no confirmed current n8n caller, removal confidence insufficient |
| POST | `/moneytrack-test` | `REMOVE` | removed from active production surface |

These dispositions are final for API-2C. API-3 must include retained `/i18n` and deprecated-but-active `/me` in auth hardening while `/me` remains present.

## Decision evidence

The read-only preflight completed against active/version-consistent workflows with n8n health PASS and global active direct business writers `0`.

- `/api/v1/i18n`: real production use confirmed in retained nginx logs via requests to `/webhook/api/v1/i18n` with referrer `https://app.moneytrackapp.xyz/`.
- `/moneytrack-test`: `0` hits across the available 15 nginx access-log files and no supported consumer identified.
- `/api/v1/me`: coarse substring search produced two matches, but one was unrelated Grafana `/api/v1/metadata`; the other was `GET /api/v1/me` returning `401`, not the production n8n path `/webhook/api/v1/me`. Use of the n8n endpoint therefore was not proven, but confidence was insufficient for immediate removal.

## Production removal

Workflow:

- ID: `DER2Lc3dT2afyQhy`
- name: `MoneyTrack`
- before: version counter `4004`, active version `6a112eb5-25cf-41fa-9a7a-e3535523ef8b`, 142 nodes
- after: version counter `4005`, active version `b621bc5a-76f0-4f3e-97cb-e49e56e17214`, 141 nodes

The production mutation removed only:

1. node `Webhook moneytrack-test` (`n8n-nodes-base.webhook`, node id `e14a05c6-061d-4bf2-99c2-08f63bb07980`);
2. connection source key `Webhook moneytrack-test`, whose only downstream edge was `Normalize Webhook Input`.

No downstream node was removed. `Normalize Webhook Input` and all remaining Telegram/update execution paths were preserved.

## Production gate evidence

The fail-safe cutover completed with:

```text
harness_syntax=PASS
python_compile=PASS
fresh_identity_gate=PASS
target_ownership_gate=PASS
me_i18n_presence_before=PASS
API-2C transform PASS
API-2C structural removal verifier PASS
pre_put_drift_guard=PASS
PUT workflow=DER2Lc3dT2afyQhy http=200
production_update=PASS
production_candidate_parity=PASS
moneytrack_test_active_count=0 PASS
api_v1_me_active_count=1 PASS
api_v1_i18n_active_count=1 PASS
global_direct_business_writer_nodes=0 PASS
n8n health=PASS
```

Exact isolation after cutover proved:

- exactly one node removed: `Webhook moneytrack-test`;
- remaining 141 nodes unchanged;
- only the matching connection source removed;
- all remaining webhook signatures unchanged;
- workflow stayed active and `versionId == activeVersionId`;
- `/api/v1/me` remains active;
- `/api/v1/i18n` remains active;
- global direct business writers remain `0`.

## Invariants preserved

API-2C did not:

- change retained six endpoint contracts;
- change backend/domain functions;
- change Telegram command/update ingress;
- change business writes;
- reopen API-2A or API-2B;
- introduce auth changes reserved for API-3.

## Gate result

```text
API-2C DISPOSITIONS              PASS
MONEYTRACK-TEST REMOVAL         PASS
STRUCTURAL ISOLATION            PASS
PRODUCTION/CANDIDATE PARITY     PASS
/ME PRESERVED                   PASS
/I18N PRESERVED                 PASS
GLOBAL DIRECT BUSINESS WRITERS  PASS — 0
N8N HEALTH                      PASS

API-2C — COMPLETE
```

## Next

- API-3 — centralized Telegram InitData/auth/ownership/idempotency hardening;
- API-4 — final API integration gate.
