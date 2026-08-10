# UX-022R3 — Grouping Accounts Contract

## Invariant

An account has exactly one runtime role determined by data:

- **operational account** — may have direct transactions/transfers and MUST NOT have children;
- **grouping account** — may have children and MUST NOT have direct transactions/transfers.

A grouping account may itself be a child of another grouping account.
A grouping account MUST NOT be used as a default posting account.

## Forbidden transitions

- An account that has any direct transaction or transfer history cannot become a parent.
- A default posting account cannot become a parent until its default references are moved to an operational account.
- A grouping account cannot receive a new transaction, opening balance, adjustment, income, expense, transfer debit, or transfer credit.
- Moving operation history into a grouping account is forbidden by the same database invariant.

Canonical errors:

- `ACCOUNT_PARENT_HAS_OPERATIONS`
- `ACCOUNT_PARENT_IS_DEFAULT`
- `ACCOUNT_GROUP_NOT_POSTABLE`

## Legacy normalization

Existing data may contain a parent account with direct operation history. UX-022R3 normalizes that legacy state once during migration.

For each such active parent:

1. Find active direct leaf children with the same currency as the parent.
2. Skip a child when moving history to it would collapse a direct parent↔child transfer or create two opening balances on one account.
3. If several safe children remain, choose deterministically by `sort_order`, then `id`.
4. If no existing child is safe, create a dedicated active leaf child with the same currency and account type, named `<parent> — операции`.
5. Move all direct transactions from the parent to the chosen/created child.
6. Rewrite transfer endpoints that reference the parent to that same child.
7. Move per-currency and `user_settings` default-account references from the parent to that child.
8. The parent is then a pure grouping account.

Every rewritten transaction, transfer and default reference is journaled. A child created only for normalization is journaled as well. UX-022 rollback restores the original references/history and removes the migration-created child only when it has no new post-migration data.

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

Normal hierarchy changes never silently move or rewrite transaction history. The only automatic history move is the explicit one-time UX-022R3 legacy normalization described above.
