# PROD-H — Production Hardening

## Status

- **PROD-H1 — COMPLETE: Runtime / Recovery Inventory**
- **PROD-H2 — COMPLETE: Backup & Restore Hardening**
- **PROD-H3 — COMPLETE: Runtime / Secrets / TLS Hardening**
- **PROD-H4 — COMPLETE: Monitoring / Off-host / Runbook**
- **PROD-H5 — COMPLETE: Final Production Hardening Gate**
- **PROD-H — COMPLETE**

## Base

MoneyTrack backend-domain and API programs were already closed before PROD-H. PROD-H remained operational hardening only; it did not reopen business/domain/API scope.

## Goal

Make the existing production runtime recoverable, observable and reproducible enough to operate as a production service rather than undocumented server state.

## PROD-H1 — COMPLETE

Production baseline established:

- Ubuntu 24.04.4 LTS;
- `n8n`, n8n PostgreSQL (`postgres`) and MoneyTrack PostgreSQL (`moneytrack-db`) run with restart policy `unless-stopped`;
- n8n persistent state uses Docker volume `n8n_n8n_data`;
- n8n metadata PostgreSQL uses Docker volume `n8n_postgres_data`;
- MoneyTrack PostgreSQL uses `/opt/moneytrack/postgres/data`;
- DB readiness and n8n health PASS;
- public TLS valid; certbot timer enabled + active;
- UFW baseline exposes only 22/80/443 publicly; n8n port 5678 is loopback-only;
- persisted n8n encryption key exists in `/home/node/.n8n/config`, mode `600`, value never printed;
- deployment provenance is `/root/stack/n8n/docker-compose.yml` and `/opt/moneytrack/postgres/docker-compose.yml`.

H1 identified the gaps later closed by H2/H3: no proved MoneyTrack recovery chain, mutable n8n image, moving PostgreSQL tag and unbounded Docker logs.

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

## PROD-H4 — COMPLETE

### Operational gate — PASS

After installing local operator monitoring, the H4 acceptance rerun reported:

```text
operational_failures=0
operational_warnings=3
PROD-H4 operational_gate=PASS_WITH_DEBT_REVIEW
```

Confirmed PASS:

- hardened image pins, overlays, restart policies and log rotation;
- protected Compose context snapshots mode `600`;
- both PostgreSQL readiness checks, n8n health and canonical API `401 INIT_DATA_MISSING` smoke;
- daily backup and weekly restore-verification timers;
- latest backup hashes/freshness and last recovery service results;
- root/backup filesystem usage ~24%;
- certbot timer;
- `n8n.moneytrackapp.xyz` TLS with 77 days remaining at final observation;
- `app.moneytrackapp.xyz` TLS with 81 days remaining at final observation;
- no MoneyTrack/certbot failed systemd units;
- `operator_alerting_hook=PASS`.

### Operator monitoring — PASS

Installed:

- `/usr/local/lib/moneytrack/prod-h4-operator-alert.sh`;
- `/usr/local/lib/moneytrack/prod-h4-health-monitor.sh`;
- `moneytrack-health-monitor.timer`, enabled + active;
- `OnFailure` hook on `moneytrack-backup.service`;
- `OnFailure` hook on `moneytrack-restore-verify.service`;
- `OnFailure` hook on `moneytrack-health-monitor.service`;
- durable local alert state under `/var/lib/moneytrack/operator-alerts/`.

Initial monitor execution PASS. Monitoring checks service/API/recovery/disk/TLS state approximately every 15 minutes. No external recipient is assumed or invented.

### Operations runbook — PASS

`docs/runbooks/PROD-H-operations.md` documents:

- quick service/API health checks;
- protected backup-now;
- isolated restore verification;
- safe Compose recreation using base + permanent hardening overlay + interpolation snapshot;
- persistent-volume safety boundary;
- log policy;
- TLS checks;
- recovery-critical files;
- local alert trail and controlled residual debt.

### Controlled residual MEDIUM debt

The following risks are explicitly accepted, non-blocking and recorded in `/etc/moneytrack/prod-h4-debt.env`:

1. **off-host backup** — no external destination/usable AWS identity was proved;
2. **external push alerting** — no real operator recipient was proved, so no Telegram/email destination was guessed;
3. **automation checkout drift** — `/home/adm_mt/moneytrack-automation` retains modified `bin/release.sh` and untracked `config/`; secret-bearing state is not normalized blindly.

The local backup remains on the same `/dev/sda1` host failure domain; this is the operational consequence of the accepted off-host debt.

## PROD-H5 — COMPLETE

Final read-only acceptance re-ran H4 and the installed health monitor.

Final evidence:

- `h4_operational_gate_dependency=PASS`;
- accepted warnings limited exactly to `off_host_backup_path`, `backup_failure_domain`, `automation_checkout_drift`;
- `operational_warning_scope=PASS`;
- installed health monitor PASS with zero failures and zero warnings;
- health-monitor timer enabled + active;
- backup/restore/health `OnFailure` hooks PASS;
- durable alert state PASS;
- controlled MEDIUM debt record PASS;
- operations runbook gate PASS;
- `blocker_debt=0`;
- `high_debt=0`;
- `PROD-H5 final_gate=PASS`;
- `PROD-H=COMPLETE`.

## Final gate

```text
BLOCKER debt: 0
HIGH debt:    0

Accepted MEDIUM debt:
- off-host backup / same-host failure domain
- external push alerting recipient/destination
- automation checkout drift

PROD-H5 final_gate=PASS
PROD-H=COMPLETE
```

## Next

Close the PROD-H branch through normal PR/merge workflow. Do not create another PROD-H phase absent new production evidence. MINIAPP remains a separate track after PROD-H.
