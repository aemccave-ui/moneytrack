# PROD-H — Production Hardening

## Status

- **PROD-H1 — COMPLETE**
- **PROD-H2 — CURRENT: recovery correctness PASS; recurring schedule pending**
- PROD-H3 — Runtime / Secrets / TLS Hardening
- PROD-H4 — Monitoring & Runbook Gate
- PROD-H5 — Final Production Hardening Gate

## Base

The MoneyTrack backend-domain and API programs are closed. PROD-H is separate from MiniApp UX work and must not reopen closed API/domain phases without fresh blocking evidence.

## Goal

Make the existing production runtime recoverable, observable and reproducible enough to operate as a production service rather than as undocumented server state.

## PROD-H1 — production inventory — COMPLETE

Fresh read-only inventory and focused evidence resolution completed against production.

### Healthy baseline

- Ubuntu 24.04.4 LTS;
- root filesystem ~24% used, ~148 GB available;
- `n8n`, n8n PostgreSQL (`postgres`) and MoneyTrack PostgreSQL (`moneytrack-db`) running;
- restart policy `unless-stopped` on all three containers;
- n8n persistent state on Docker volume `n8n_n8n_data`;
- n8n metadata PostgreSQL on Docker volume `n8n_postgres_data`;
- MoneyTrack PostgreSQL bind-mounted from `/opt/moneytrack/postgres/data`;
- MoneyTrack DB readiness PASS, size ~51 MB;
- n8n metadata DB readiness PASS, size ~42 MB;
- n8n health PASS;
- public MoneyTrack TLS valid;
- UFW active; inspected public rules expose only 22/80/443;
- n8n port 5678 is loopback-only.

### H1.1 resolved findings

**Encryption key persistence — PASS.**

`N8N_ENCRYPTION_KEY` is absent from the container environment, but n8n persistent `/home/node/.n8n/config` exists with mode `600`, owner `node:node`, and contains a non-empty persisted encryption key. The value was not printed. No key rotation is required.

**Deployment provenance — FOUND.**

- n8n + n8n PostgreSQL: `/root/stack/n8n/docker-compose.yml`;
- MoneyTrack PostgreSQL: `/opt/moneytrack/postgres/docker-compose.yml`.

**Exact current runtime versions — CAPTURED.**

- n8n: runtime `2.22.5`, image ref `n8nio/n8n:latest`, current immutable digest `n8nio/n8n@sha256:a49bc161141d6c4b9c495b5a6e3c7c1932e61d2ed2fe3fdca01262064b4b23ca`;
- both PostgreSQL containers: PostgreSQL `16.14`, image ref `postgres:16`, current image ID `sha256:4b7183ac05f8ef417db21fd72d71047a4238340c261d3cc3ddb6d579ab5071ae`.

**Docker log rotation — GAP CONFIRMED.**

All three critical containers use Docker `json-file` logging with empty log options. No `max-size` / `max-file` limit is active.

**Certbot renewal — PASS.**

`certbot.timer` is installed, enabled and active.

**Automation checkout drift — MEDIUM debt.**

`/home/adm_mt/moneytrack-automation` is on `main` but contains modified `bin/release.sh` and untracked `config/`. `config/` may contain secrets and must not be committed blindly.

## Debt after H1

### HIGH

**H-01 — MoneyTrack backup / restore verification does not exist.**

Addressed by PROD-H2 manual backup + isolated restore proof. Recurring scheduling remains to complete H2 operations.

**H-02 — production n8n is referenced as `n8nio/n8n:latest`.**

Current known-good runtime is 2.22.5 and current immutable digest is known. Required in PROD-H3.

### MEDIUM

**M-01 — Docker logs have no rotation limits.** Required in PROD-H3.

**M-02 — PostgreSQL uses moving `postgres:16` tags.** PROD-H3 will pin to `postgres:16.14` or record an explicit controlled-minor-update exception.

**M-03 — automation checkout has local drift.** PROD-H3/4 must document the real deployment source and keep secrets out of Git.

**M-04 — cert renewal exists, but expiry/failure alerting is not yet proved.** Required in PROD-H4 unless existing monitoring evidence closes it.

**M-05 — off-host backup durability is not proved.** Local backup/restore proof is H2; off-host posture is resolved no later than H4/final gate.

## PROD-H2 — Backup & Restore Hardening

### Manual backup evidence — PASS

A protected production backup was created at:

`/opt/moneytrack/backups/20260809T141520Z`

Backup results:

- `moneytrack.dump` PASS, 3,848,859 bytes;
- `n8n-metadata.dump` PASS, 8,367,226 bytes;
- `n8n-data.tar.gz` PASS, 497,675 bytes;
- protected runtime configuration archive PASS;
- SHA256 manifest PASS;
- `COMPLETE` marker PASS.

The backup contains MoneyTrack PostgreSQL, n8n metadata PostgreSQL, n8n persistent recovery-critical state (including the persisted encryption key) and runtime recovery configuration. Secret values were not printed.

### Isolated restore verification — PASS

The backup hashes were verified and both database dumps were restored into temporary PostgreSQL containers with no published host ports. The restore rehearsal used the exact currently running PostgreSQL image ID rather than a moving tag.

Restore evidence:

- backup hash verification PASS;
- isolated restore containers READY with host ports NONE;
- MoneyTrack PostgreSQL restore PASS;
- MoneyTrack restored schema PASS with 30 tables;
- n8n metadata restore PASS;
- n8n restored metadata schema PASS with 93 tables;
- restored n8n encryption key present PASS, value not printed;
- production MoneyTrack DB health PASS after rehearsal;
- production n8n metadata DB health PASS after rehearsal;
- production n8n health PASS after rehearsal;
- temporary restore resources cleanup armed and trap-controlled.

**Recovery correctness is therefore proven.** No restore was performed against production data or volumes.

### Recurring recovery policy — pending installation

The prepared production schedule is:

- daily protected backup via `moneytrack-backup.timer`;
- default local retention: 14 days;
- weekly isolated restore verification via `moneytrack-restore-verify.timer`;
- `Persistent=true` on both timers so missed schedules run after downtime;
- recovery executables copied to `/usr/local/lib/moneytrack/` so jobs do not depend on Git checkout state.

Retention deletes only canonical timestamp-named directories containing a valid `COMPLETE` marker and the required backup files. Incomplete or malformed directories are skipped rather than deleted.

Off-host durability is intentionally not misrepresented as solved by this local schedule. It remains MEDIUM debt for PROD-H4/final gate.

### H2 close gate

PROD-H2 closes when both timers are installed, enabled and active after systemd validation. The already-completed manual backup and isolated restore rehearsal do not need to be repeated during installation.

## PROD-H3 — frozen target

After H2 schedule installation:

- replace mutable n8n `latest` with known-good 2.22.5 / immutable digest while preserving current config, persistent volume and database;
- add bounded Docker `json-file` log rotation to `n8n`, `postgres` and `moneytrack-db`;
- make Compose recovery path explicit without committing secret values;
- resolve PostgreSQL reproducibility by pinning the currently running 16.14 release or accepting a controlled-minor policy explicitly;
- preserve the current persisted n8n encryption key;
- validate merged Compose configuration before any container recreation;
- recreate only the affected services and reassert DB/API health after each bounded change.

The official PostgreSQL image catalog currently exposes an exact `16.14` tag, so pinning the currently running database release is available if the current Compose layout supports the bounded change.

## PROD-H4 — target

- backup-failure visibility;
- disk/log/certificate/service-health operational checks;
- off-host backup decision/implementation;
- concise deploy/restart/rollback/restore runbook.

## Exit gate

PROD-H closes only when:

- production restart/recreation path is credible and documented;
- both PostgreSQL databases have recurring backups and successful isolated restore evidence;
- n8n recovery-critical persistent state, including the encryption key, is protected;
- critical images are reproducible or have an explicit accepted exception;
- log growth has a bound or alert;
- TLS renewal and expiry/failure monitoring is operational;
- critical service health and backup failures can surface to an operator;
- final gate reports no unresolved BLOCKER/HIGH debt.

## Next

Install and verify the PROD-H2 systemd recovery schedule. If green, mark H2 COMPLETE and proceed directly to PROD-H3 runtime pinning and log rotation.
