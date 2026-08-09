# PROD-H — Production Hardening

## Status

- **PROD-H1 — COMPLETE**
- **PROD-H2 — COMPLETE: Backup & Restore Hardening**
- **PROD-H3 — CURRENT: Runtime / Secrets / TLS Hardening**
- PROD-H4 — Monitoring & Runbook Gate
- PROD-H5 — Final Production Hardening Gate

## Base

The MoneyTrack backend-domain and API programs are closed. PROD-H is separate from MiniApp UX work and must not reopen closed API/domain phases without fresh blocking evidence.

## Goal

Make the existing production runtime recoverable, observable and reproducible enough to operate as a production service rather than as undocumented server state.

## PROD-H1 — production inventory — COMPLETE

Fresh production inventory established the current baseline:

- Ubuntu 24.04.4 LTS;
- root filesystem ~24% used, ~148 GB available;
- `n8n`, n8n PostgreSQL (`postgres`) and MoneyTrack PostgreSQL (`moneytrack-db`) running with restart policy `unless-stopped`;
- n8n persistent state on Docker volume `n8n_n8n_data`;
- n8n metadata PostgreSQL on Docker volume `n8n_postgres_data`;
- MoneyTrack PostgreSQL bind-mounted from `/opt/moneytrack/postgres/data`;
- MoneyTrack DB and n8n metadata DB readiness PASS;
- n8n health PASS;
- public MoneyTrack TLS valid;
- UFW active; inspected public rules expose only 22/80/443;
- n8n port 5678 loopback-only.

Resolved H1.1 evidence:

- n8n persistent `/home/node/.n8n/config` exists mode `600`, owner `node:node`, and contains a non-empty persisted encryption key; no key rotation is required;
- n8n + n8n PostgreSQL Compose source: `/root/stack/n8n/docker-compose.yml`;
- MoneyTrack PostgreSQL Compose source: `/opt/moneytrack/postgres/docker-compose.yml`;
- n8n runtime `2.22.5`, current immutable digest `n8nio/n8n@sha256:a49bc161141d6c4b9c495b5a6e3c7c1932e61d2ed2fe3fdca01262064b4b23ca`;
- both PostgreSQL runtimes: `16.14`, current image ID `sha256:4b7183ac05f8ef417db21fd72d71047a4238340c261d3cc3ddb6d579ab5071ae`;
- Docker log rotation gap confirmed on all three critical containers;
- `certbot.timer` installed, enabled and active;
- automation checkout local drift remains MEDIUM operational debt and secret-bearing `config/` must not be committed blindly.

## PROD-H2 — Backup & Restore Hardening — COMPLETE

### Manual recovery proof — PASS

Protected backup created at `/opt/moneytrack/backups/20260809T141520Z`.

Backup set includes:

- MoneyTrack PostgreSQL custom-format dump;
- n8n metadata PostgreSQL custom-format dump;
- n8n persistent recovery-critical state including persisted encryption material;
- protected runtime recovery configuration;
- SHA256 manifest and COMPLETE marker.

All required backup artifacts were non-empty and hash-manifest generation passed.

### Isolated restore proof — PASS

The backup was restored only into temporary PostgreSQL containers with no published host ports. The rehearsal used the exact currently-running PostgreSQL image ID.

Evidence:

- backup hash verification PASS;
- isolated restore containers READY, host ports NONE;
- MoneyTrack restore PASS, restored schema 30 tables;
- n8n metadata restore PASS, restored schema 93 tables;
- restored n8n encryption key presence PASS without printing the value;
- production MoneyTrack DB health PASS after rehearsal;
- production n8n metadata DB health PASS after rehearsal;
- production n8n health PASS after rehearsal.

### Recurring recovery schedule — PASS

Installed recovery executables are independent of Git checkout state under `/usr/local/lib/moneytrack/`.

Systemd schedule:

- `moneytrack-backup.timer` — daily protected backup, enabled + active;
- local retention default — 14 days;
- `moneytrack-restore-verify.timer` — weekly isolated restore verification, enabled + active;
- both timers use `Persistent=true`.

Observed first scheduled triggers after installation:

- daily backup: 2026-08-10 ~03:16 CEST;
- weekly restore verify: 2026-08-16 ~05:16 CEST.

**H-01 is closed. Recovery correctness and recurring local recovery operations are proven.**

Off-host durability remains MEDIUM debt for PROD-H4/final gate and is not misrepresented as solved by local backups.

## Debt entering PROD-H3

### HIGH

**H-02 — production n8n Compose still references mutable `n8nio/n8n:latest`.**

Known-good runtime is 2.22.5 and the exact immutable digest is known. H3 must eliminate mutable recreation risk.

### MEDIUM

**M-01 — critical Docker logs have no rotation limits.**

All three critical containers use `json-file` with empty options.

**M-02 — PostgreSQL Compose uses moving `postgres:16` tags.**

Both current runtimes are PostgreSQL 16.14. H3 will pin the exact release tag `postgres:16.14` while preserving the current persistent data and service definitions.

**M-03 — automation checkout has local drift.**

Operational source-of-truth must be documented in H4. Secret-bearing config remains outside Git.

**M-04 — cert renewal exists but expiry/failure alerting is not yet proved.**

Resolved in H4 unless existing monitoring evidence closes it.

**M-05 — off-host backup durability is not proved.**

Resolved no later than H4/final gate.

## PROD-H3 — Runtime / Secrets / TLS Hardening — CURRENT

### Frozen implementation model

Do not edit or normalize the existing secret-bearing base Compose files in-place as part of repository work.

Use explicit non-secret hardening overlays alongside the production Compose files:

- `/root/stack/n8n/docker-compose.prod-h.yml`;
- `/opt/moneytrack/postgres/docker-compose.prod-h.yml`.

The overlays contain only image pins and Docker logging policy.

Target runtime pins:

- n8n -> `n8nio/n8n@sha256:a49bc161141d6c4b9c495b5a6e3c7c1932e61d2ed2fe3fdca01262064b4b23ca`;
- n8n PostgreSQL -> `postgres:16.14`;
- MoneyTrack PostgreSQL -> `postgres:16.14`.

Target log policy on `n8n`, `postgres`, `moneytrack-db`:

```yaml
logging:
  driver: json-file
  options:
    max-size: "10m"
    max-file: "5"
```

### Safety gates

Before recreation:

1. latest protected backup with COMPLETE marker must exist and pass SHA256 verification;
2. current n8n runtime must still be 2.22.5 and current critical PostgreSQL runtimes must still be 16.14;
3. Compose provenance paths must still match H1 evidence;
4. current persistent mount sources and restart policies are captured;
5. hardening overlay candidates must pass `docker compose config` before installation;
6. known-good current images are tagged locally as temporary rollback images;
7. no production data volume is deleted or recreated.

Cutover is bounded service recreation only. Persistent volumes/bind mounts and existing environment/config remain inherited from base Compose.

After each affected project recreation, reassert:

- expected image reference/version;
- expected persistent mount source;
- restart policy `unless-stopped`;
- Docker log rotation options;
- PostgreSQL readiness;
- n8n health;
- MoneyTrack API missing-auth smoke remains canonical `401 INIT_DATA_MISSING` on a retained endpoint.

On failure after mutation, use local rollback image tags and base Compose to restore the prior runtime, then reassert health.

### Secrets / TLS status entering H3

- persisted n8n encryption key: PASS, preserve unchanged;
- `n8n.env` permissions: restricted mode `600`;
- certbot renewal timer: PASS;
- no secret rotation is required by H3.

## PROD-H4 — target

- backup-failure visibility;
- disk/log/certificate/service-health operational checks;
- off-host backup decision/implementation;
- concise deploy/restart/rollback/restore runbook;
- document the required Compose invocation including hardening overlays;
- document automation checkout drift without committing secrets.

## PROD-H5 — final gate

Read-only acceptance: no unresolved BLOCKER/HIGH debt, recovery schedule active, restore proof valid, runtime pins active, log rotation active, TLS/service/DB health PASS, monitoring/runbook/off-host decisions resolved.

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

Run PROD-H3 preflight. If green, execute the bounded runtime hardening cutover and proceed directly to PROD-H4.
