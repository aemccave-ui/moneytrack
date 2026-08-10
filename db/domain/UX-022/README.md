# UX-022 database boundary

This directory contains the PostgreSQL/domain side of Accounts Explorer and Account Lifecycle.

Execution order:

1. `010_filter_presets.sql` — immutable server-side presets and Telegram-user ownership resolver.
2. `020_account_lifecycle.sql` — account lifecycle, hierarchy, archive/delete, and atomic history reassignment.
3. `025_account_lifecycle_hardening.sql` — compatibility/safety overlays that must be applied after the lifecycle boundary. It also installs the schema-tolerant default-account guard used by archive/delete so optional legacy account-reference columns do not become a compile-time dependency.
4. `030_accounts_explorer_read_models.sql` — dated balance snapshots and period/category operation read models.
5. `035_accounts_explorer_read_model_hardening.sql` — selected-account FX missing-rate hardening. The tree still receives the full account snapshot, while excluded-account FX gaps cannot blank a selected total.
6. `900_verify_contract.sql` and `905_reference_inventory.sql` — rollback-only migration validation; never persisted by the validation gate.
7. `990_rollback_code.sql` — non-destructive code rollback. Preset rows/table are deliberately retained to avoid user-data loss.

`../../../scripts/ux022-render-migration.sh` is the single migration-body source used by both validation and persistent apply. `../../../scripts/ux022-migration-gate.sh` wraps that exact body plus both verifiers in one real-schema transaction and rolls it back. Persistent migration is allowed only after this gate and a runtime backup succeed.

n8n is not a business-domain owner for this track: adapters may only authenticate/validate HTTP input and call versioned `moneytrack.*` functions.
