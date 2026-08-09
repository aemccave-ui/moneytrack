# BE-DOM-005 — FX Rate Ingestion Domain Extraction

## Status

BE-DOM-005 is accepted for merge.

The production cutover removed the final active direct n8n business-table writer. The remaining manual FX smoke attempts failed in test harness mechanics before workflow execution and are explicitly non-blocking because backend semantics, production cutover parity, runtime version consistency, and zero-writer state are already independently verified.

## Scope

Workflow:

- `eOidxxekEVyAjeep` — `MoneyTrack Update Exchange Rates`

Legacy writer:

- node `Upsert exchange rates`
- table `moneytrack.exchange_rates_usd`
- legacy behavior: `INSERT ... ON CONFLICT (rate_date, currency_code) DO UPDATE`

Read-only consumers of `exchange_rates_usd` were left unchanged.

## Backend boundary

Introduced:

- `moneytrack.fx_upsert_usd_rate_v1(date, varchar, numeric, text)`

The function preserves the legacy persistence contract:

- insert `(rate_date, currency_code, usd_rate, source)`
- conflict key `(rate_date, currency_code)`
- update `usd_rate`, `source`, and `created_at = now()`

No new FX business semantics were introduced in this slice.

## Backend verification

Rollback-safe verifier passed:

- insert semantics: PASS
- conflict update semantics: PASS
- single-key semantics: PASS
- verifier rollback: PASS
- synthetic fixture leak: `0`

## Candidate verification

Candidate workflow characteristics:

- node count: `5`
- graph SHA-256: `c9a532d9d49bacc8e4f663f1a208df0408ef162765ab75f8c427b22a0792f262`
- changed nodes: exactly `Upsert exchange rates`
- graph topology unchanged: PASS
- target node query-only change: PASS
- backend call present: PASS
- direct FX writer bypass: `0`
- candidate FX workflow direct business mutations: `0`

Before cutover, all non-FX active direct business mutations were already `0`.

## Production cutover

Production state before cutover matched the frozen baseline exactly.

Cutover result:

- HTTP PUT: `200`
- active: `true`
- workflow version changed from `19` to `20`
- new version ID: `7621233c-4d66-459c-b512-ba3517fc356f`
- `versionId == activeVersionId`: PASS
- post-cutover node parity with candidate: PASS
- post-cutover graph parity with candidate: PASS
- backend boundary call present: PASS
- production direct FX writer count: `0`
- n8n restart/health: PASS
- runtime export node parity with candidate: PASS
- runtime export graph parity with candidate: PASS

## Global zero-writer result

After the production cutover, scanning all active n8n workflow SQL returned:

- global direct business mutation inventory: `(0 rows)`
- `global_direct_business_writer_nodes = 0`

Domain-by-domain bypass counts:

- finance: `0`
- receipt/catalog: `0`
- user lifecycle/preferences: `0`
- budget: `0`
- FX: `0`

Context at verification time:

- active workflows: `10`
- active PostgreSQL nodes: `91`

This is the primary acceptance invariant for Backend Domain Extraction.

## Manual runtime-smoke attempts

Several attempts were made to force-run the scheduled FX workflow immediately. They did not expose a product defect and are not used as a merge blocker.

Observed harness limitations:

1. `n8n execute --id=...` inside the running n8n container initially collided with the already-bound Task Broker port.
2. With isolated runner ports, CLI execution rejected the scheduled workflow because the command requires a CLI-executable start node (`Missing node to start execution`).
3. A structurally identical inactive shadow workflow was prepared with only `Schedule Trigger` changed to `Execute Workflow Trigger`; graph and all downstream nodes remained identical.
4. Initial shadow API create returned schema validation `400` because copied production settings contained an unsupported additional property.
5. After reducing settings to API-safe `executionOrder`, structural validation passed, but the API key returned `403 Forbidden` on workflow creation.

No shadow workflow was created in the final attempt. Production workflow identity, version, backend boundary, and zero-writer state remained unchanged.

The n8n CLI `execute --file` route is not available in modern n8n; the flag was removed in n8n 1.37.0. Further synthetic harness work would add risk and noise without increasing confidence in the architectural invariant.

A natural scheduled execution may be observed later as operational evidence, but it is not required to merge this domain extraction.

## Acceptance

BE-DOM-005 merge gate:

- backend domain function installed: PASS
- backend rollback verifier: PASS
- candidate isolation: PASS
- production cutover exact parity: PASS
- active version consistency: PASS
- n8n health: PASS
- global direct business writers: `0`
- manual forced-run smoke: NON-BLOCKING / HARNESS-LIMITED

BE-DOM-005 is therefore complete for the architectural objective.

Next phase: `FINAL ZERO-WRITER / ARCHITECTURE GATE`.
