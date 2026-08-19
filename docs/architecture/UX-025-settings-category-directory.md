# UX-025 — Settings & Space Category Directory

## Status

**SOURCE DESIGN / IMPLEMENTATION IN PROGRESS**

Canonical base: `main@69591733490170205d5cc87f82a86c174451f2ce`.

Implementation branch: `agent/ux-025-settings-category-directory`.

No PostgreSQL, n8n, Preview, or production mutation is part of this design checkpoint.

## Product goal

1. The Settings screen exposes two collapsed-by-default sections:
   - Security management;
   - Category management.
2. Categories become a full mutable Space-owned directory with create/edit/archive/reparent/reorder semantics.
3. The MiniApp top-level navigation is decomposed so every bottom-navigation screen has its own JSX file.

## Recovered canonical facts

### Settings frontend

`miniapp/src/SettingsPortal.jsx` currently:

- intercepts document clicks and opens Settings by matching button text containing `Настройки`;
- owns category loading, category-tree flattening, category row editing and the Settings modal shell;
- renders `SecuritySettings` inline above categories;
- exposes every category as an always-visible input/select/save row.

`miniapp/src/SecuritySettings.jsx` already encapsulates the PIN/biometric/security behavior and should remain a dedicated child component unless a proven regression requires changes.

### Current category API

`miniapp/src/api.js` currently exposes only `updateCategory({ categoryId, name, flowType })` for category mutation.

The accepted SPC-001 Space-native transaction-reference boundary is `moneytrack.finance_transaction_reference_space_v1(actor_user_id, space_id)`. It returns only active categories belonging to the active Space and marks them editable.

Therefore UX-025 category CRUD must extend the accepted Space-owned model; it must not revive the legacy user-owned `category_update_v1` tenancy semantics.

## Target frontend structure

Top-level screen contract:

```text
miniapp/src/screens/
  HomeScreen.jsx
  AccountsScreen.jsx
  BudgetsScreen.jsx
  StatisticsScreen.jsx
  SettingsScreen.jsx
```

Settings children may remain smaller components under:

```text
miniapp/src/screens/settings/
  SecuritySettings.jsx
  CategorySettings.jsx
  CategoryEditor.jsx
  CategoryTree.jsx
```

`App.jsx` becomes the React screen orchestrator. A bottom-navigation item must switch React state directly; Settings must not be opened through DOM text interception.

## Settings interaction contract

Default state:

```text
Security management   = collapsed
Category management   = collapsed
```

Only one section should be open at a time unless later product requirements explicitly change this.

Collapsed rows should include concise status information such as PIN state and category count without loading/rendering the complete form surface unnecessarily.

## Category directory contract

Every non-template category instance belongs to exactly one Space.

Required operations:

- READ active category tree;
- CREATE category;
- UPDATE localized display name and `flow_type`;
- REPARENT category;
- REORDER siblings through `sort_order`;
- ARCHIVE/DELETE with history-safe semantics.

Target category fields used by the contract:

- `id`;
- `space_id`;
- `code`;
- localized `name`;
- `flow_type` (`income` or `expense`);
- `parent_id`;
- `sort_order`;
- `is_active`;
- actor/provenance metadata where supported by the canonical schema.

### Same-Space and hierarchy invariants

Backend, not frontend, is authoritative for all invariants:

1. Actor is an active member of the target Space.
2. Category belongs to that Space.
3. Parent, when supplied, belongs to the same Space and is active.
4. Category cannot parent itself.
5. A category cannot be moved below one of its descendants.
6. Reordering cannot affect categories in another Space.
7. A referenced historical category is not physically destroyed in a way that breaks existing transactions, budgets, receipt projections or other financial references.

### Archive/delete semantics

Preferred contract:

- unused leaf category: physical delete may be allowed if dependency checks prove no references and no children;
- referenced category: archive through `is_active=false`;
- category with active children: reject delete/archive until children are moved/archived, unless a future explicitly accepted bulk policy exists.

Historical records keep their category identity and remain renderable.

## API target

The exact transport may use separate endpoints or one PATCH route, but the capabilities must be explicit:

```text
GET    /api/v1/categories
POST   /api/v1/categories
PATCH  /api/v1/categories
DELETE /api/v1/categories
```

A PATCH may include:

```json
{
  "category_id": 17,
  "name": "Продукты",
  "flow_type": "expense",
  "parent_id": 2,
  "sort_order": 30
}
```

The `X-MoneyTrack-Space-Id` header remains untrusted routing input. PostgreSQL/backend membership and same-Space checks are authoritative.

## Delivery phases

### UX-025A — Screen decomposition

- introduce one top-level JSX file per bottom-navigation screen;
- remove Settings DOM click interceptor;
- keep accepted Home/Accounts/SPC-001 behavior unchanged;
- no backend/runtime mutation.

### UX-025B — Space category CRUD/hierarchy backend

- add canonical Space-native category CRUD functions;
- add cycle/same-Space/reference guards;
- expose n8n/API adapter routes;
- add source and runtime verification;
- controlled migration/apply only after exact-head gates pass.

### UX-025C — Settings UX and Preview acceptance

- collapsed Settings sections;
- category tree view mode;
- create/edit/move/reorder/archive UI;
- regression tests for Security, SPC-001, TransactionEditor, ReceiptModal, Budgets and category filtering;
- Preview acceptance before merge.

## Acceptance

```text
SETTINGS_DEFAULT_COLLAPSED=PASS
SECURITY_SECTION_EXPAND_COLLAPSE=PASS
CATEGORY_SECTION_EXPAND_COLLAPSE=PASS

CATEGORY_CREATE=PASS
CATEGORY_RENAME=PASS
CATEGORY_FLOW_CHANGE=PASS
CATEGORY_REPARENT=PASS
CATEGORY_REORDER=PASS
CATEGORY_DELETE_OR_ARCHIVE=PASS
CATEGORY_CYCLE_GUARD=PASS
CATEGORY_SAME_SPACE_GUARD=PASS
CATEGORY_HISTORY_PRESERVED=PASS
CATEGORY_SPACE_ISOLATION=PASS

HOME_SCREEN_OWN_JSX=PASS
ACCOUNTS_SCREEN_OWN_JSX=PASS
BUDGETS_SCREEN_OWN_JSX=PASS
STATISTICS_SCREEN_OWN_JSX=PASS
SETTINGS_SCREEN_OWN_JSX=PASS
SETTINGS_DOM_CLICK_INTERCEPTOR=ABSENT

SEC001_REGRESSION=PASS
SPC001_REGRESSION=PASS
TRANSACTION_EDITOR_CATEGORY_PICKER=PASS
RECEIPT_CATEGORY_PICKER=PASS
BUDGET_CATEGORY_REFERENCES=PASS
```

## Mutation state at this checkpoint

```text
SOURCE_DOC_MUTATION=YES
DB_MUTATION=NONE
N8N_MUTATION=NONE
PREVIEW_MUTATION=NONE
PRODUCTION_MUTATION=NONE
```
