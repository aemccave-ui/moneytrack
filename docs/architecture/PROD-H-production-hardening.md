# PROD-H — Production Hardening

## Status

CURRENT — production hardening inventory / gate definition.

## Base

The MoneyTrack backend domain extraction and API programs are closed. The stable API baseline is merged to `main`.

PROD-H is deliberately separate from MiniApp UX work. It does not add business features and must not reopen closed API/domain phases without fresh blocking evidence.

## Goal

Make the existing production runtime recoverable, observable, reproducible and operationally safe enough to treat the current API/backend baseline as a production service rather than a manually maintained server state.

## Scope

PROD-H covers:

1. **Runtime reproducibility**
   - identify the actual production containers/services;
   - identify image tags/versions;
   - identify restart policies and persistence mounts;
   - identify deployment/config source of truth;
   - flag mutable/unpinned runtime dependencies.

2. **Secrets and configuration hygiene**
   - verify required secrets/config are present without printing values;
   - verify sensitive env/config files are not broadly readable;
   - identify secrets that exist only as undocumented server state;
   - do not rotate working secrets merely to satisfy the phase.

3. **Database durability / recovery**
   - verify both MoneyTrack business PostgreSQL and n8n metadata PostgreSQL are reachable;
   - identify persistent storage;
   - identify actual backup jobs/artifacts;
   - define retention and off-host requirements;
   - perform a restore rehearsal later only against an isolated target, never against production.

4. **Reverse proxy / TLS**
   - inventory nginx routing relevant to MoneyTrack;
   - verify TLS certificate validity/expiry for current public endpoints;
   - identify accidental HTTP exposure or proxy drift.

5. **Health / restart / capacity**
   - verify n8n health;
   - inspect Docker restart policies and health state;
   - inspect filesystem capacity, Docker disk usage and container log growth;
   - identify single-host risks explicitly rather than hiding them.

6. **Monitoring / alerting**
   - inventory existing timers, cron jobs, monitors and alerting hooks;
   - require an actionable minimum for service health, disk exhaustion, certificate expiry and backup failure;
   - monitoring implementation belongs here only when evidence shows a gap.

7. **Operational runbook**
   - document start/stop/restart locations;
   - document safe deploy path;
   - document backup/restore path;
   - document rollback and incident checks;
   - keep the runbook executable and concise.

## Out of scope

PROD-H does not include:

- MiniApp layout/UX polish;
- new accounts/transactions/budget/features;
- backend domain redesign;
- new API endpoints;
- speculative microservices/Kubernetes migration;
- replacing n8n solely for architectural purity;
- destructive recovery testing against production;
- secret rotation without a concrete reason.

## Initial read-only gate

The first pass must capture fresh production evidence for:

- running MoneyTrack/n8n/PostgreSQL containers;
- container images, restart policy, health and mounts;
- database readiness and approximate DB sizes;
- env/config file permissions and presence of required runtime variables without values;
- current backup evidence (jobs/timers/artifacts);
- nginx MoneyTrack routes;
- TLS certificate expiry;
- host and Docker disk usage;
- Docker log file sizes;
- existing cron/systemd monitoring/backup jobs;
- global n8n health.

The inventory is allowed to return WARN/DEBT. Its purpose is to separate real production blockers from generic hardening advice.

## Severity model

- **BLOCKER** — credible data-loss, unrecoverable deployment, expired/broken TLS, production service cannot restart reliably, required secret/config is missing, database/runtime is unhealthy.
- **HIGH** — no proven backup/restore path, mutable image tags for critical stateful services, sensitive files broadly readable, uncontrolled log/disk growth, no persistence where required.
- **MEDIUM** — incomplete alerting, undocumented deploy/rollback, weak retention/off-host posture, version drift with a known manual recovery path.
- **LOW** — housekeeping/documentation improvements that do not materially increase current production risk.

## Phase decomposition

The exact implementation work is evidence-driven. Default structure:

- **PROD-H1 — Runtime / Recovery Inventory** — read-only current-state gate.
- **PROD-H2 — Backup & Restore Hardening** — only gaps proven by H1.
- **PROD-H3 — Runtime / Secrets / TLS Hardening** — only gaps proven by H1.
- **PROD-H4 — Monitoring & Runbook Gate** — minimum alerts + executable operations handover.
- **PROD-H5 — Final Production Hardening Gate** — read-only acceptance.

Subphases with no work are closed as N/A rather than generating artificial implementation.

## Exit gate

PROD-H closes only when:

- production service restart/recovery path is documented and credible;
- MoneyTrack DB and n8n metadata DB have a defined backup path and successful isolated restore evidence;
- required persistent data is on persistent mounts/volumes;
- critical images are pinned to reproducible versions or an explicit accepted exception exists;
- sensitive config permissions are acceptable;
- TLS is valid with an expiry-monitoring path;
- disk/log growth has an operational control or alert;
- critical service health and backup failures can surface to an operator;
- n8n and both databases are healthy;
- the final gate reports no BLOCKER/HIGH unresolved debt.

## Next

Run PROD-H1 read-only inventory. Use its evidence to build the smallest possible hardening plan. After PROD-H closes, continue with the separate MINIAPP track.
