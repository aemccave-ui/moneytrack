# UX-022 — Accounts Explorer / Account Lifecycle

## Baseline

This track is rebuilt on the current production-hardened `main` baseline.

Safety rules:

- preview frontend only: `https://preview.moneytrackapp.xyz` / `/var/www/moneytrack-miniapp-preview`;
- never deploy this track to `https://app.moneytrackapp.xyz` without an explicit production-delivery gate;
- n8n remains a thin HTTP/auth adapter;
- business reads/writes belong behind PostgreSQL backend/domain boundaries;
- source/static/lint/build validation must pass before DB, workflow, runtime, or preview mutation;
- any runtime mutation must have a tested rollback point.

The pre-sync UX branch head is preserved at `backup/ux-022-pre-main-sync-20260810` (`168c2375e597e1daaa8545507e88561f09758e78`).

## Required invariants

- balance is a dated snapshot at `date_to`; `date_from` never changes the snapshot;
- categories affect income/expense/result/operations, never balance snapshot;
- the tree may receive the full active-account snapshot, but `total_base` and `snapshot_missing_rate_count` are scoped only to the selected accounts; an FX gap on an excluded account must not blank the selected total;
- parent is a real account and may have its own operations and balance;
- parent total = parent own balance + all descendant balances;
- internal transfers wholly inside a selected parent subtree are hidden/zero-impact at parent level;
- presets store immutable account/category ID snapshots, never dates;
- hierarchy edit changes only `parent_id` and must reject self/cycle/cross-user/archived targets;
- moving account history is an atomic ownership reassignment, not a financial transfer and never performs hidden FX;
- archive requires zero own balance and cannot hide active descendants;
- archive/delete must protect default-account references without compiling against optional legacy column names; unknown legacy reference shapes fail closed at migration validation;
- hard delete is allowed only for a truly empty account and never cascades financial history;
- rollback-only migration validation and persistent migration apply consume the same rendered migration body, preventing validate/apply drift.

## Delivery gates

1. source implementation
2. static validation
3. lint
4. build
5. migration validation
6. runtime backup
7. API/workflow deployment
8. real webhook readiness
9. runtime contract smoke
10. preview frontend deploy
11. preview artifact identity check
12. UX acceptance at 320/360/390 px

No merge or production delivery is implied by this document.
