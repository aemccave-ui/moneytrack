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

## Legacy normalization

Existing data may contain a parent account with direct operation history. UX-022R3 normalizes that legacy state once during migration.

For each such active parent:

1. Find active direct child accounts with the same currency as the parent.
2. Only a leaf child is eligible to receive financial history.
3. Exactly one eligible child is required.
4. Move all direct transactions from the parent to that child.
5. Rewrite transfer endpoints that reference the parent to that same child.
6. The parent is then a pure grouping account.

The migration fails without changing committed data when:

- no same-currency leaf child exists;
- more than one same-currency leaf child exists;
- a transfer exists directly between the parent and selected child, because it would collapse into a self-transfer;
- both parent and selected child have an opening balance.

The migration journals every rewritten transaction and transfer so the normalization can be reversed by the UX-022 rollback.

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
