# UX-022R3 — Grouping Accounts Contract

## Invariant

An account has exactly one runtime role determined by data:

- **operational account** — may have direct transactions/transfers and MUST NOT have children;
- **grouping account** — may have children and MUST NOT have direct transactions/transfers.

A grouping account may itself be a child of another grouping account.

## Forbidden transitions

- An account that has any direct transaction or transfer history cannot become a parent.
- A grouping account cannot receive a new transaction, opening balance, adjustment, income, expense, transfer debit, or transfer credit.
- Moving operation history into a grouping account is forbidden by the same database invariant.

Canonical errors:

- `ACCOUNT_PARENT_HAS_OPERATIONS`
- `ACCOUNT_GROUP_NOT_POSTABLE`

## UI semantics

- Parent/grouping row balance is descendants aggregate only.
- No separate own-parent amount in parentheses.
- Parent accordion expands/collapses child accounts only.
- Parent row never opens an operations accordion.
- Operations are available only on leaf/operational accounts.

## Split-account workflow

If an existing operational account must be split into several accounts:

1. Create a new empty grouping account.
2. Rename the existing operational account to the desired leaf name.
3. Move the existing operational account under the new grouping account.
4. Create/move additional leaf accounts under the grouping account.

Existing operation history is never silently moved or rewritten by hierarchy changes.
