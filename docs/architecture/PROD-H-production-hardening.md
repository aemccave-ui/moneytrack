# PROD-H — Production Hardening

## Status

- **PROD-H1 — COMPLETE**
- **PROD-H2 — CURRENT: Backup & Restore Hardening**
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

The production containers carry Compose provenance labels that point to these files.

**Exact current runtime versions — CAPTURED.**

- n8n: runtime `2.22.5`, image ref `n8nio/n8n:latest`, current immutable digest `n8nio/n8n@sha256:a49bc161141d6c4b9c495b5a6e3c7c1932e61d2ed2fe3fdca01262064b4b23ca`;
- both PostgreSQL containers: PostgreSQL `16.14`, image ref `postgres:16`, current image ID `sha256:4b7183ac05f8ef417db21fd72d71047a4238340c261d3cc3ddb6d579ab5071ae`.

**Docker log rotation — GAP CONFIRMED.**

All three critical containers use Docker `json-file` logging with empty log options. No `max-size` / `max-file` limit is active.

**Certbot renewal — PASS.**

`certbot.timer` is installed, enabled and active.

**MoneyTrack backup/recovery — GAP CONFIRMED.**

Search found extensive HabitsTrack backup and restore-verification assets, but no MoneyTrack-specific backup artifacts or systemd units. `/opt/moneytrack/backups` exists as a candidate directory, but no proved MoneyTrack recovery chain was found.

**Automation checkout drift — MEDIUM debt.**

`/home/adm_mt/moneytrack-automation` is on `main` but contains modified `bin/release.sh` and untracked `config/`. `config/` may contain secrets and must not be committed blindly.

## Current debt after H1

### HIGH

**H-01 — MoneyTrack backup / restore verification does not exist.**

Required in PROD-H2.

**H-02 — production n8n is referenced as `n8nio/n8n:latest`.**

Current known-good runtime is 2.22.5 and current immutable digest is known. Required in PROD-H3.

### MEDIUM

**M-01 — Docker logs have no rotation limits.** Required in PROD-H3.

**M-02 — PostgreSQL uses moving `postgres:16` tags.** PROD-H3 must either pin exact immutable images or record an explicit controlled-minor-update exception.

**M-03 — automation checkout has local drift.** PROD-H3/4 must document the real deployment source and keep secrets out of Git.

**M-04 — cert renewal exists, but expiry/failure alerting is not yet proved.** Required in PROD-H4 unless existing monitoring evidence closes it.

**M-05 — off-host backup durability is not proved.** Local backup/restore proof is H2; off-host posture is resolved no later than H4/final gate.

## PROD-H2 — frozen scope

PROD-H2 implements the smallest safe recovery chain for the current production architecture.

Backup set:

1. MoneyTrack PostgreSQL database (`moneytrack-db`, database `moneytrack`) as PostgreSQL custom-format dump;
2. n8n metadata PostgreSQL (`postgres`, database `n8n`) as PostgreSQL custom-format dump;
3. n8n persistent data volume, including the persisted encryption key, as a protected archive;
4. runtime recovery configuration files as a protected archive where available;
5. manifest with hashes, timestamps, image/version evidence and no secret values.

Security rules:

- backup root and backup instances are mode `700`;
- secret-bearing backup files are mode `600`;
- bot token/encryption key/env values are never printed;
- restore verification never targets production databases or volumes;
- temporary restore containers have no published host ports and are removed automatically.

Restore proof:

- verify backup hashes;
- restore MoneyTrack dump into an isolated temporary PostgreSQL container;
- prove core MoneyTrack tables/functions exist after restore;
- restore n8n metadata dump into a separate isolated temporary PostgreSQL container;
- prove n8n schema/tables exist after restore;
- extract the n8n data archive into a temporary host directory and prove a persisted encryption key exists without printing it;
- remove all temporary restore containers/files;
- reassert production DB/n8n health after the rehearsal.

H2 does **not** yet install a recurring timer. First obtain one successful manual backup + isolated restore proof. Scheduling/retention is installed only after that proof succeeds.

## PROD-H3 — frozen target

After H2 succeeds:

- replace mutable n8n `latest` with the known-good 2.22.5 immutable image/digest while preserving current config/volume/database;
- add bounded Docker log rotation to critical containers;
- make Compose recovery path explicit and version controlled without committing secret values;
- resolve PostgreSQL image reproducibility policy;
- preserve the current persisted n8n encryption key.

## PROD-H4 — target

- scheduled backup + retention;
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

Run PROD-H2 manual backup + isolated restore verification. If green, install the recurring recovery schedule and proceed directly to PROD-H3.
