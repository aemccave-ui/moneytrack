# SPC-001 — Canonical Base + Tenancy Forensic

## Status

**SPC-001A / FORENSIC COMPLETE — SOURCE ONLY**

No PostgreSQL, n8n, preview, or production runtime mutation is part of this forensic phase.

## Canonical base

- Repository: `aemccave-ui/moneytrack`
- Canonical branch: `main`
- Forensic base SHA: `30d91d4d2bf4558361c6b7586d8bb2fcde103044`
- Implementation branch: `agent/spc-001-space-tenancy`
- Canonical post-merge `MoneyTrack Source Gates` run #35: success at the same SHA.
- UX-024 source is present under `db/domain/UX-024/` and the accepted MiniApp source.
- SEC-001 source is present under `db/domain/SEC-001/`, `scripts/sec001-*`, `ops/sec001/`, and the accepted MiniApp source.

The integration-base blocker is therefore closed for this starting SHA.

## Executive finding

MoneyTrack already has `workspaces` and `workspace_members`, and user bootstrap already creates one active personal workspace plus owner membership. However, this is **not currently the financial tenancy boundary**.

Canonical finance ownership is still enforced through `user_id` in accounts, transactions, transfers, receipts/catalog, budgets, defaults, filters, read models, and mutations. The existing workspace is primarily lifecycle/current-context metadata.

Therefore SPC-001 is a genuine tenancy migration, not a UI selector change.

## Existing workspace finding

`moneytrack.user_bootstrap_v1` currently:

1. resolves/creates one `app_users` row;
2. ensures one active personal `workspaces` row owned by that user;
3. ensures a `workspace_members` row with role `owner`;
4. separately copies template accounts and categories into **user-owned** rows;
5. stores `user_settings.current_workspace_id`.

No inspected finance read/write boundary uses `workspace_members` as authorization or `workspace_id` as financial ownership.

### Physical-model recommendation

Prefer reusing the existing `workspaces` / `workspace_members` tables as the physical backing of the product concept **Space**, instead of creating a second parallel tenant registry.

This is a source-design recommendation, not runtime evidence. Read-only runtime preflight must still verify the deployed schema before any migration is applied.

Rules if reused:

- `workspaces.owner_user_id` is administration ownership only;
- owner must also be an active member;
- `workspace_members.role` must not become financial RBAC;
- all active members receive equal ordinary financial CRUD rights;
- finance rows must be tenant-scoped by Space/workspace id, never by owner/user id;
- client-provided Space id remains untrusted and requires server-side membership verification on every relevant request.

## Classification matrix

| Domain / object | Current ownership / behavior | SPC-001 class | Target rule |
|---|---|---|---|
| `app_users` | Telegram identity keyed to user | B — USER_GLOBAL | Remains user-owned identity |
| `user_security` | PIN verifier/security state by `user_id` | B — USER_GLOBAL | Remains user-global; never Space-scoped |
| `user_unlock_sessions` | unlock token hash/session by `user_id` | B — USER_GLOBAL | Remains user-global; Space membership checked separately on each request |
| `user_biometric_credentials` | credential by `user_id` + device | B — USER_GLOBAL | Remains user-global |
| `languages` | platform metadata | A — GLOBAL_PLATFORM | Remains global |
| `currencies` | platform ISO/reference data | A — GLOBAL_PLATFORM | Remains global |
| FX/rate reference data | platform conversion data | A — GLOBAL_PLATFORM | Remains global |
| operation source vocabulary | persisted `manual/text/voice/photo_receipt` semantics | A — GLOBAL_PLATFORM | Remains global vocabulary |
| template rows owned by sentinel/template user `0` | account/category/default templates | A — GLOBAL_PLATFORM | Remain templates only; do not turn into a user/Space tenant |
| `workspaces` | personal context/lifecycle shell | tenant registry candidate | Becomes physical Space registry if runtime schema confirms source |
| `workspace_members` | lifecycle membership with role | membership boundary candidate | Active membership is authorization boundary; role does not control financial CRUD |
| `user_settings.language_code` | user preference | B — USER_GLOBAL | Remains user-global |
| `user_settings.current_workspace_id` | user pointer to current workspace | D — USER_SPACE_PREFERENCE | Current/active Space pointer only; not authorization |
| `user_settings.base_currency`, `report_currency` | currently user-global/mixed financial settings | C — SPACE_OWNED financial default | Move/derive into Space financial settings; do not leave ambiguous user-global financial ownership |
| `user_settings.default_expense_account_id`, `default_income_account_id` | currently references user-owned accounts | C — SPACE_OWNED financial default | Move/derive into Space financial settings with same-Space invariant |
| `accounts` non-template | `user_id` owner | C — SPACE_OWNED | Add Space ownership; account hierarchy cannot cross Space |
| `user_default_accounts` non-template | `user_id` + account | C — SPACE_OWNED | Space-scoped default mapping; account must belong to same Space |
| `transactions` | `user_id` owner | C — SPACE_OWNED | `space_id` is tenancy boundary; preserve creator/actor separately |
| `transfers` | `user_id` owner | C — SPACE_OWNED | One Space only; both accounts and transfer share same Space |
| `category_catalog` non-template | `user_id` owner | C — SPACE_OWNED | Space-owned category instances; templates stay global |
| `category_catalog_translations` | follows category instance | A or C by parent category | Global for global templates; Space-relative when attached to Space category instance |
| `product_catalog` non-template | `user_id` owner | C — SPACE_OWNED | Space-owned product/classification instance |
| `budget_rules` | `user_id` owner | C — SPACE_OWNED | Space-owned; category/account references must stay in Space |
| `filter_presets` | `user_id`, contains account/category ids | D — USER_SPACE_PREFERENCE | Key by user + Space; referenced ids must belong to that Space |
| receipt captured merchant/date/total/currency/raw parser item text/qty/price/image provenance | currently stored under user-owned receipt aggregate | E — CAPTURE_SOURCE | Shared source/capture layer; immutable parser provenance where current contract says immutable |
| receipt financial transaction/account association | currently user-owned | C — SPACE_OWNED projection | Belongs to one Space transaction projection |
| receipt item category/product assignment | currently mutable on universal `receipt_items.category_id/product_id` | C — SPACE_OWNED projection classification | Must become per-projection classification; different Spaces may classify same source item differently |
| text/voice/photo/manual ingress provenance | currently represented through source fields/workflows | E — CAPTURE_SOURCE | Canonical `capture_event` source/provenance layer in SPC-001C |
| user deletion requests | user lifecycle | B — USER_GLOBAL | Remain user-global lifecycle/security data |

## User-scoped financial boundary inventory

### Canonical transaction writes

`db/domain/BE-DOM-001/010_finance_write_domain.sql`

- `finance_create_transaction_v1(p_user_id, ...)` is user-owned.
- account validation requires `accounts.user_id = p_user_id`.
- category validation requires `category_catalog.user_id = p_user_id`.
- source idempotency is unique on `(user_id, source_type, source_id)`.
- transaction persistence writes `transactions.user_id`.

Target: actor + Space boundary, Space-local references, creator/actor preserved separately.

### Transfer writes

`db/domain/BE-DOM-001/020_finance_transfer_write_domain.sql`

- `finance_create_transfer_v1(p_user_id, ...)` is user-owned.
- source/destination accounts are both validated by `user_id`.
- transfer idempotency is currently user-scoped.

Target: transfer has exactly one Space; both accounts must belong to that Space. No cross-Space transfer in SPC-001.

### Transaction mutation / delete

`db/domain/BE-DOM-001/030_finance_transaction_mutation_domain.sql`

- transaction and target account are resolved by `user_id`.
- aggregate delete deletes receipt children through receipt/transaction `user_id`.

Target: membership + Space ownership; member financial rights equal; original author survives edits by another member.

### Dashboard / accounts / API reads

Inspected canonical backend/read-model files include:

- `db/domain/BE-DOM-001/001_finance_read_models.sql`;
- `db/domain/API-2A/010_live_api_read_models.sql`;
- `db/domain/UX-022/030_accounts_explorer_read_models.sql` and hardening layers;
- `db/domain/UX-024/020_operation_source_read_models.sql`.

Current read semantics resolve Telegram identity to an internal user and join accounts, transactions, transfers and categories using that user's `user_id`.

Target: request is actor + Space; authenticate actor, enforce SEC unlock where required, assert active membership, then scope every finance join by Space. No aggregate all-Spaces dashboard in SPC-001.

### Account lifecycle

`db/domain/UX-022/020_account_lifecycle.sql` and hardening layers:

- create/copy/edit/move/archive/delete and balance logic resolve a user and scope account/transaction/transfer/default references by `user_id`.
- account hierarchy is currently user-scoped.

Target: all account lifecycle actions are Space-scoped; parent/child accounts cannot cross Space; ordinary member financial rights are equal.

### Filter presets

`db/domain/UX-022/010_filter_presets.sql`:

- presets are owned by `user_id`;
- embedded account/category ids are validated against the user's finance directories.

Target: user + Space preference. Preset ownership remains personal to the user, but every referenced finance id belongs to the selected Space.

### Receipts and catalog

`db/domain/BE-DOM-002/010_receipt_catalog_domain.sql`:

- receipt duplicate identity, receipt ownership, categories and products are currently `user_id`-scoped;
- receipt ingest creates a user-owned transaction;
- product catalog upsert is keyed by user;
- receipt item category is currently directly mutable/shared on the item row.

Target: split source provenance from Space financial projection. Receipt parser/source facts may be shared; category/product classification must be projection-specific in SPC-001C.

### Budgets

`db/domain/BE-DOM-004/010_budget_domain.sql`:

- budget CRUD is user-owned;
- category references are validated by `user_id`.

Target: Space-owned budgets and same-Space references.

### User bootstrap

`db/domain/BE-DOM-003/010_user_lifecycle_domain.sql`:

- already creates one personal workspace + owner membership;
- finance directories are still copied to user-owned rows;
- `user_settings.current_workspace_id` is already present.

This gives SPC-001 a migration anchor: existing users already have a personal workspace in canonical source, but runtime preflight must prove deployed-data consistency before relying on it.

### User erasure — blocking semantic conflict

`db/domain/BE-DOM-001/040_user_erasure_domain.sql` currently deletes:

- the user's finance rows;
- memberships;
- every workspace owned by that user, including other users' memberships in those workspaces.

This behavior is incompatible with shared Space financial ownership.

SPC target:

- removing a member revokes future access but preserves Space financial history;
- user deletion must not destroy a shared Space merely because the deleted user authored records;
- ownership-transfer semantics are not invented in SPC-001.

Until owner-deletion semantics are made explicitly safe, runtime destructive deletion must fail closed for an owner of a shared Space.

### SEC-001

`db/domain/SEC-001/010_application_lock.sql` confirms the accepted security state is explicitly user-global (`user_security`, unlock sessions, biometric credentials are keyed by user).

SPC must add membership as a separate runtime predicate. Membership is never encoded into a long-lived unlock token. Removing a member must take effect on the next request even while an unlock token remains valid.

### UX-024

`db/domain/UX-024/010_operation_source_and_datetime_guard.sql` confirms accepted source vocabulary and receipt datetime immutability are implemented in the canonical source but still use `user_id` as finance ownership.

SPC must preserve:

- persisted source semantics (`manual`, `text`, `voice`, `photo_receipt`);
- no content/time heuristics for source type;
- receipt-backed datetime immutability;
- ordinary transaction datetime editability.

The ownership predicate changes to actor + Space without weakening these UX-024 rules.

## n8n / API inventory

Tracked workflow snapshots include:

- `workflows/moneytrack-DER2Lc3dT2afyQhy.json` — main Telegram orchestration;
- `workflows/moneytrack-miniapp-api-7TJ2xQTxLsTydXZc.json` — MiniApp API;
- catalog/rate workflows.

The accepted API baseline documents eight HTTP endpoints, with finance reads/writes already delegated to PostgreSQL backend/read-model boundaries and zero active direct business-table writers in n8n.

SPC therefore must keep n8n as a thin authenticated adapter and move Space authorization into canonical backend/domain boundaries.

No workflow snapshot is imported or mutated in this forensic phase.

## MiniApp inventory

Relevant current source surfaces include:

- `App.jsx` / Home;
- `AccountsExplorer.jsx`;
- `RecentOperations.jsx`;
- `TransactionEditor.jsx`;
- `ReceiptModal.jsx`;
- `TransferEditor.jsx`;
- `SettingsPortal.jsx`;
- `SecurityGate.jsx` / `SecuritySettings.jsx`;
- `api.js`.

SPC-001B must make active Space context explicit across financial screens and must clear old-Space state before loading a newly selected Space.

No frontend mutation is part of this forensic phase.

## Required Stage-A migration invariants derived from forensic

1. Existing financial `user_id` cannot remain the tenancy boundary.
2. A canonical Space id must own every financial record after migration.
3. Existing users map deterministically to exactly one Personal Space.
4. Template/global rows remain global and do not receive an arbitrary user Space.
5. Owner is administration only; active membership grants normal financial CRUD.
6. Original actor/authorship is stored separately from Space ownership.
7. Every foreign finance reference must be validated against the same Space.
8. Transfers remain single-Space.
9. User-global SEC-001 data remains user-global.
10. User erasure cannot delete shared financial history.
11. Legacy UX-022/UX-023/UX-024 behavior must be preserved except where ownership is deliberately migrated from user to Space.
12. No DB/n8n/preview/production mutation occurs until source gates, migration dry-run, reconciliation and rollback evidence pass.

## Open design points / debt

### Financial defaults currently mixed into `user_settings`

`base_currency`, `report_currency`, `default_expense_account_id`, and `default_income_account_id` have financial meaning and currently live beside user-global preferences. They must be separated or explicitly Space-scoped; leaving them as a single user-global value would violate independent financial Spaces.

### Owner deletion

SPC-001 does not invent ownership transfer. Runtime user deletion of an owner with shared Space obligations must fail closed until a product-safe ownership-transfer/delete policy is explicitly accepted.

### Receipt split

Current receipt tables combine captured source facts with mutable financial categorization. The final model must introduce capture/source provenance plus per-Space projection classification in SPC-001C.

### Legacy physical names

The physical tables are named `workspaces` / `workspace_members`, while the product concept is Space. Renaming physical tables would add migration risk without product value. Reuse with a documented semantic rename is preferred unless read-only runtime preflight proves an incompatible deployed schema.

## Phase gate

```text
CANONICAL_BASE=PASS
DEPENDENCY_CLOSURE=PASS
TENANCY_INVENTORY=PASS
DATA_CLASSIFICATION=PASS
SCHEMA_MUTATION=NONE
N8N_MUTATION=NONE
PREVIEW_MUTATION=NONE
PRODUCTION_MUTATION=NONE
```

## Next source phase

Proceed to **SPC-001A — Tenancy Foundation** in source only:

- define the Space/membership canonical backend boundary;
- add deterministic/idempotent/rollbackable existing-user migration source;
- add Space ownership + actor metadata to financial data;
- add same-Space invariants and reconciliation tooling;
- add tenant-isolation fixtures/verifier;
- add dedicated SPC-001 source gate;
- keep runtime untouched until GitHub CI is green on the exact implementation SHA.
