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

## Frontend continuity rule

R3 changes account-domain semantics only. It MUST NOT regress established frontend interaction behavior.

Canonical R3 frontend behavior:

- Home renders in natural DOM order; CSS `order` MUST NOT move `Последние операции` above the balance header.
- Operation rows use compact horizontal swipe actions with icons.
- Account rows expose exactly `Изменить / Архив / Удалить`; icons and labels are laid out horizontally.
- Any open operation/account swipe closes after 2 seconds and closes immediately when another swipe opens anywhere in the MiniApp view.
- Account move has no `⋯` shortcut or Move sheet: long press activates haptic/wiggle, then the whole account card follows the finger; valid drop targets are highlighted.
- The drag source/subtree cannot be used as its own target; final move still goes through the canonical `moveAccount` API/domain path.
- An account excluded from the current selection remains visible but its card is visually muted; the old `Счёт исключён из текущей выборки` status text is not shown.
- Hidden absolute action layers that create ghost vertical lines on account cards are forbidden.
- Accounts uses the same global FAB pattern as Home with one `Счёт` action and the reliable account-create sheet.
- Home/Accounts switching uses keyed screen containers and does not use `window.scrollTo` recovery hacks.
- These rules coexist with R3 grouping semantics: group rows never open operations and never show a separate own-parent amount.

## Runtime state

The R3 database migration is already persistently applied and verified. Frontend refinements after that migration are preview-only and MUST NOT reapply or rollback the R3 database migration.

## Split-account workflow

If an existing operational account must be split into several accounts:

1. Create a new empty grouping account.
2. Rename the existing operational account to the desired leaf name.
3. Move the existing operational account under the new grouping account.
4. Create/move additional leaf accounts under the grouping account.

Normal hierarchy changes never silently move or rewrite transaction history. The only automatic history move is the explicit one-time UX-022R3 legacy normalization described above.
