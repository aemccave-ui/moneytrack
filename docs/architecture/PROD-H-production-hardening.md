# PROD-H — Production Hardening

## Status

- **PROD-H1 — COMPLETE: Runtime / Recovery Inventory**
- **PROD-H2 — COMPLETE: Backup & Restore Hardening**
- **PROD-H3 — COMPLETE: Runtime / Secrets / TLS Hardening**
- **PROD-H4 — CURRENT: Monitoring / Off-host / Runbook**
- **PROD-H5 — PREPARED: Final Production Hardening Gate**

## Base

MoneyTrack backend-domain and API programs are already closed. PROD-H is operational hardening only and must not reopen business/domain/API scope without fresh blocking evidence.

## Goal

Make the existing production runtime recoverable, observable and reproducible enough to operate as a production service rather than undocumented server state.

## PROD-H1 — COMPLETE

Production baseline established:

- Ubuntu 24.04.4 LTS;
- `n8n`, n8n PostgreSQL (`postgres`) and MoneyTrack PostgreSQL (`moneytrack-db`) running with restart policy `unless-stopped`;
- n8n persistent state on Docker volume `n8n_n8n_data`;
- n8n metadata PostgreSQL on Docker volume `n8n_postgres_data`;
- MoneyTrack PostgreSQL bind-mounted from `/opt/moneytrack/postgres/data`;
- DB readiness and n8n health PASS;
- public TLS valid; certbot timer enabled + active;
- UFW active; inspected public rules expose only 22/80/443; n8n port 5678 loopback-only;
- persisted n8n encryption key present in `/home/node/.n8n/config`, mode `600`, value never printed;
- deployment provenance found at `/root/stack/n8n/docker-compose.yml` and `/opt/moneytrack/postgres/docker-compose.yml`.

H1 identified the gaps addressed in later phases: no proved MoneyTrack recovery chain, mutable n8n image, moving PostgreSQL tag and unbounded Docker logs.

## PROD-H2 — COMPLETE

### Recovery correctness — PASS

Protected recovery set contains:

- MoneyTrack PostgreSQL custom-format dump;
- n8n metadata PostgreSQL custom-format dump;
- n8n persistent recovery-critical state including encryption material;
- protected runtime recovery configuration;
- SHA256 manifest and `COMPLETE` marker.

Isolated restore rehearsal restored both databases only into temporary PostgreSQL containers with no published host ports.

Evidence:

- backup hash verification PASS;
- MoneyTrack restored schema PASS with 30 tables;
- n8n metadata restored schema PASS with 93 tables;
- restored n8n encryption-key presence PASS without printing value;
- production DB/n8n health PASS after rehearsal.

### Recurring recovery — PASS

Installed recovery executables are independent of Git checkout under `/usr/local/lib/moneytrack/`.

- `moneytrack-backup.timer` — daily protected backup, enabled + active;
- local retention — 14 days;
- `moneytrack-restore-verify.timer` — weekly isolated restore verification, enabled + active;
- both recovery timers use `Persistent=true`.

H-01 is closed.

## PROD-H3 — COMPLETE

Permanent production hardening files:

- `/root/stack/n8n/docker-compose.prod-h.yml`;
- `/opt/moneytrack/postgres/docker-compose.prod-h.yml`;
- `/root/stack/n8n/compose-interpolation.prod-h.sh` mode `600`;
- `/opt/moneytrack/postgres/compose-interpolation.prod-h.sh` mode `600`.

Accepted image/runtime policy:

- n8n: immutable digest `n8nio/n8n@sha256:a49bc161141d6c4b9c495b5a6e3c7c1932e61d2ed2fe3fdca01262064b4b23ca`, runtime `2.22.5`;
- n8n PostgreSQL: `postgres:16.14`;
- MoneyTrack PostgreSQL: `postgres:16.14`.

Accepted Docker log policy on all three critical containers:

```yaml
logging:
  driver: json-file
  options:
    max-size: "10m"
    max-file: "5"
```

Final accepted cutover proved:

- Compose interpolation context recovered without exposing values;
- preflight and candidate Compose render PASS;
- target image versions PASS;
- n8n metadata PostgreSQL recreation PASS;
- n8n recreation + API registration PASS;
- MoneyTrack PostgreSQL recreation PASS;
- image/version pins PASS;
- persistent mounts and restart policies preserved;
- complete container environment parity PASS without printing values;
- log rotation PASS on all three containers;
- persisted n8n encryption key remained present;
- API missing-auth contract remained canonical `401 INIT_DATA_MISSING`;
- production health PASS;
- fresh post-hardening protected backup PASS including overlays/context snapshots.

Accepted post-hardening recovery point: `/opt/moneytrack/backups/20260809T145418Z`.

First-attempt rollback evidence remains preserved in `docs/architecture/PROD-H3-first-cutover-attempt.md` and is not accepted production state.

H3 closed:

- H-02 mutable n8n `latest` — CLOSED;
- M-01 unbounded Docker logs — CLOSED;
- M-02 moving PostgreSQL tag — CLOSED;
- Compose recreation context — PROTECTED / REPRODUCIBLE.

## PROD-H4 — CURRENT

### Operational gate evidence

After fixing harness-only scoping/TLS defects, the H4 read-only production gate completed with:

```text
operational_failures=0
operational_warnings=4
PROD-H4 operational_gate=PASS_WITH_DEBT_REVIEW
```

Confirmed PASS:

- hardened image pins, overlays, restart policies and log rotation;
- protected Compose context snapshots mode `600`;
- both PostgreSQL readiness checks, n8n health and canonical API `401` smoke;
- daily backup and weekly restore-verification timers;
- latest backup hashes/freshness and last recovery service results;
- root/backup filesystem usage ~24%;
- certbot timer;
- `n8n.moneytrackapp.xyz` TLS with 77 days remaining at observation time;
- `app.moneytrackapp.xyz` TLS with 81 days remaining at observation time;
- no MoneyTrack/certbot failed systemd units.

Remaining warnings:

1. `operator_alerting_hook` — no operator-visible failure hook installed yet;
2. `off_host_backup_path` — no off-host MoneyTrack destination proved;
3. `backup_failure_domain` — local backup shares `/dev/sda1` with root;
4. `automation_checkout_drift` — modified `bin/release.sh` and untracked `config/` in `/home/adm_mt/moneytrack-automation`.

No BLOCKER/HIGH debt exists.

### External capability resolution

Narrow resolver established:

- AWS CLI present, but usable AWS identity was not proved;
- no existing remote mount was found;
- rsync present;
- `MONEYTRACK_BOT_TOKEN` exists at runtime, value not printed;
- no existing MoneyTrack `OnFailure` hook exists;
- schema contains Telegram/user identifiers, but no operator recipient was proved; no recipient value was read or guessed.

Therefore:

- do not invent an S3 bucket/account;
- do not guess a Telegram chat/user ID;
- off-host backup remains a controlled MEDIUM external dependency;
- external push alerting remains a controlled MEDIUM external dependency.

### H4 implementation bundle

Prepared:

- `scripts/prod-h4-operator-alert.sh` — durable local alert sink to journald + `/var/lib/moneytrack/operator-alerts/`;
- `scripts/prod-h4-health-monitor.sh` — recurring service/API/recovery/disk/TLS monitor;
- `scripts/prod-h4-install-operator-monitoring.sh` — installs monitor timer and `OnFailure` hooks for backup, restore verification and health monitor;
- `docs/runbooks/PROD-H-operations.md` — concise operations/recovery runbook;
- `/etc/moneytrack/prod-h4-debt.env` — non-secret controlled residual-debt decision record created by installer.

The health monitor runs approximately every 15 minutes. A failed health/backup/restore service creates a durable local operator alert. No external recipient is assumed.

Controlled residual MEDIUM debt after successful monitoring installation:

- off-host backup unavailable until an external destination/identity is supplied;
- external push notification unavailable until a real operator recipient is supplied;
- automation checkout drift remains documented and is not normalized because `config/` may be secret-bearing.

H4 closes when the installer passes and a rerun of the H4 gate reports `operator_alerting_hook=PASS` with no warnings outside the controlled MEDIUM set.

## PROD-H5 — PREPARED

`scripts/prod-h5-final-gate.sh` is read-only acceptance after H4 monitoring installation.

It requires:

- H4 operational failures = 0;
- `operator_alerting_hook=PASS`;
- no unexpected operational warning;
- only `off_host_backup_path`, `backup_failure_domain`, and `automation_checkout_drift` may remain WARN;
- installed health monitor PASS;
- health-monitor timer enabled + active;
- `OnFailure` hooks on backup, restore-verification and health-monitor services;
- durable local alert state directory;
- explicit controlled MEDIUM debt record;
- operations runbook safety/recovery commands present.

Final successful markers:

```text
blocker_debt=0
high_debt=0
PROD-H5 final_gate=PASS
PROD-H=COMPLETE
```

## Exit gate

PROD-H closes only when:

- no unresolved BLOCKER/HIGH debt remains;
- recurring backups and successful isolated restore proof remain valid;
- n8n recovery-critical persistent state remains protected;
- runtime pins and log rotation remain active;
- production recreation path is documented and reproducible;
- TLS renewal/expiry monitoring is operational;
- critical service/backup/restore failures create a durable operator-visible alert trail;
- off-host posture is implemented or explicitly retained as MEDIUM external-dependency debt;
- operations runbook exists;
- H5 final gate passes.

## Next

Install the prepared H4 local operator monitoring bundle, rerun H4 through H5, and close PROD-H if the final gate is green.
