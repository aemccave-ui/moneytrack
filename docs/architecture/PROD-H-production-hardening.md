# PROD-H — Production Hardening

## Status

CURRENT — PROD-H1 runtime/recovery inventory.

## Base

The MoneyTrack backend domain extraction and API programs are closed. The stable API baseline is merged to `main`.

PROD-H is separate from MiniApp UX work. It does not add business features and must not reopen closed API/domain phases without fresh blocking evidence.

## Goal

Make the existing production runtime recoverable, observable, reproducible and operationally safe enough to treat the current API/backend baseline as a production service rather than manually maintained server state.

## Scope

PROD-H covers runtime reproducibility, secrets/config hygiene, database recovery, reverse proxy/TLS, health/restart/capacity, monitoring/alerting and a concise operational runbook.

It explicitly does **not** include MiniApp UX, new business features, new API endpoints, speculative orchestration/platform migrations, replacing n8n for architectural purity, destructive recovery testing against production, or secret rotation without a concrete reason.

## PROD-H1 — first production inventory

Fresh read-only inventory completed against production.

### Healthy baseline

- host: Ubuntu 24.04.4 LTS;
- root filesystem: 193 GB total, 148 GB available, 24% used;
- `n8n`, n8n PostgreSQL (`postgres`) and MoneyTrack PostgreSQL (`moneytrack-db`) are running;
- all three containers use restart policy `unless-stopped`;
- n8n data is on Docker volume `n8n_n8n_data`;
- n8n PostgreSQL data is on Docker volume `n8n_postgres_data`;
- MoneyTrack PostgreSQL data is bind-mounted from `/opt/moneytrack/postgres/data`;
- MoneyTrack DB readiness: PASS, size ~51 MB;
- n8n metadata DB readiness: PASS, size ~42 MB;
- n8n health: PASS;
- n8n runtime version: `2.22.5`;
- `MONEYTRACK_BOT_TOKEN` is present without exposing its value;
- `/home/adm_mt/moneytrack-automation/config/n8n.env` exists with mode `600` and owner `adm_mt:adm_mt`;
- public TLS for `n8n.moneytrackapp.xyz` and `app.moneytrackapp.xyz` is currently valid;
- public listening ports observed are 22/80/443, while n8n port 5678 is loopback-only;
- UFW is active and allows only 22/80/443 in the inspected rules.

### Confirmed / probable debt after first pass

No active runtime BLOCKER was proven by H1. The service is currently healthy.

**HIGH — H-01: MoneyTrack backup/restore path is unproven.**

The timer inventory contains HabitsTrack backup/restore verification units, but no MoneyTrack-specific backup/restore unit was observed and no backup artifact was found under `/home/adm_mt`. This is evidence of an unproven recovery path, not proof that no external backup exists.

**HIGH — H-02: production n8n uses mutable image `n8nio/n8n:latest`.**

The current runtime reports version `2.22.5`, but recreating/pulling `latest` can move production to a different version. PROD-H must pin the known-good version or immutable digest before the final gate.

**HIGH — H-03: production recreation/deployment source is not yet proven.**

The initial search under `/home/adm_mt/moneytrack-automation` and `/home/adm_mt/moneytrack` did not find Compose/Dockerfile/systemd deployment definitions. Existing containers restart in place, but clean recreation remains unproven.

**REVIEW — M-01: `N8N_ENCRYPTION_KEY` is absent from container environment.**

This is not yet classified as a failure. n8n can persist a generated encryption key in its `.n8n` configuration. PROD-H1.1 must verify key presence in persistent n8n state without printing the value. Do not rotate or replace the key during inventory.

**REVIEW — M-02: Docker log rotation is not proven.**

Current log sizes are modest (~0.3 MB n8n, ~5 MB n8n PostgreSQL, ~17 MB MoneyTrack PostgreSQL), but the log-driver limits were not captured.

**MEDIUM — M-03: automation checkout contains local drift.**

`/home/adm_mt/moneytrack-automation` is a Git checkout but currently reports modified `bin/release.sh` and untracked `config/`. Contents must not be committed blindly because `config/` may contain secrets. The operational source-of-truth relationship must be clarified.

**MEDIUM — M-04: TLS renewal/expiry alerting is not yet proven.**

Certificates are valid now; renewal timer/monitoring evidence remains to be captured.

**MEDIUM — M-05: PostgreSQL images use `postgres:16`.**

The major version is controlled, but the exact image build/digest can still move. Final reproducibility policy must either pin exact versions/digests or explicitly accept controlled minor-version movement.

## PROD-H1.1 — evidence resolver

Before any mutation, resolve only the ambiguous items above:

1. verify whether persistent n8n config contains an encryption key without displaying it;
2. read Docker Compose provenance labels (`project`, `service`, `working_dir`, `config_files`) for the three production containers;
3. capture exact current image IDs/digests and runtime versions;
4. capture Docker log driver and rotation options;
5. verify certbot renewal timer state;
6. search systemd/unit filenames and common backup locations for MoneyTrack-specific recovery assets;
7. list automation-repository drift by filename only, never secret values.

PROD-H1.1 is read-only. It must not restart containers, pull images, modify env files or inspect secret values.

## Severity model

- **BLOCKER** — active unhealthy runtime, broken/expired TLS, required secret/config missing with no persisted equivalent, or credible immediate loss/restart failure.
- **HIGH** — no proven backup/restore path, mutable critical image with unsafe recreation path, sensitive files broadly readable, missing persistence, or unrecoverable clean deployment.
- **MEDIUM** — incomplete alerting, undocumented deploy/rollback, log-growth risk, weak off-host/retention posture, or controlled version drift.
- **LOW** — housekeeping/documentation that does not materially increase current production risk.

## Phase decomposition

- **PROD-H1 — Runtime / Recovery Inventory** — CURRENT.
- **PROD-H2 — Backup & Restore Hardening** — required unless H1.1 proves an existing MoneyTrack recovery path.
- **PROD-H3 — Runtime / Secrets / TLS Hardening** — pin runtime and resolve H1/H1.1 configuration gaps.
- **PROD-H4 — Monitoring & Runbook Gate** — minimum alerts + executable operations handover.
- **PROD-H5 — Final Production Hardening Gate** — read-only acceptance.

Subphases with no work are closed as N/A rather than generating artificial implementation.

## Exit gate

PROD-H closes only when:

- production restart/recreation path is documented and credible;
- MoneyTrack DB and n8n metadata DB have a defined backup path and successful isolated restore evidence;
- required persistent state is on persistent mounts/volumes;
- critical images are reproducible or have an explicit accepted exception;
- encryption-key persistence and sensitive config permissions are safe;
- TLS is valid with renewal/expiry monitoring;
- disk/log growth has a control or alert;
- critical service health and backup failures can surface to an operator;
- n8n and both databases are healthy;
- final gate reports no unresolved BLOCKER/HIGH debt.

## Next

Run PROD-H1.1 read-only evidence resolver. Then execute the smallest evidence-driven H2/H3 changes, not a generic hardening checklist.
