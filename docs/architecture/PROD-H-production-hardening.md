# PROD-H — Production Hardening

## Status

- **PROD-H1 — COMPLETE: Runtime / Recovery Inventory**
- **PROD-H2 — COMPLETE: Backup & Restore Hardening**
- **PROD-H3 — COMPLETE: Runtime / Secrets / TLS Hardening**
- **PROD-H4 — CURRENT: Monitoring / Off-host / Runbook**
- PROD-H5 — Final Production Hardening Gate

## Base

The MoneyTrack backend-domain and API programs are closed. PROD-H is separate from MiniApp UX work and must not reopen closed API/domain phases without fresh blocking evidence.

## Goal

Make the existing production runtime recoverable, observable and reproducible enough to operate as a production service rather than as undocumented server state.

## PROD-H1 — COMPLETE

Fresh production inventory established the baseline:

- Ubuntu 24.04.4 LTS;
- `n8n`, n8n PostgreSQL (`postgres`) and MoneyTrack PostgreSQL (`moneytrack-db`) running with restart policy `unless-stopped`;
- n8n persistent state on Docker volume `n8n_n8n_data`;
- n8n metadata PostgreSQL on Docker volume `n8n_postgres_data`;
- MoneyTrack PostgreSQL bind-mounted from `/opt/moneytrack/postgres/data`;
- MoneyTrack DB and n8n metadata DB readiness PASS;
- n8n health PASS;
- public MoneyTrack TLS valid;
- UFW active; inspected public rules expose only 22/80/443;
- n8n port 5678 loopback-only;
- persisted n8n encryption key present in `/home/node/.n8n/config`, mode `600`, value not printed;
- deployment provenance found at `/root/stack/n8n/docker-compose.yml` and `/opt/moneytrack/postgres/docker-compose.yml`;
- certbot renewal timer enabled + active.

H1 also identified the gaps later addressed by H2/H3: no proved MoneyTrack recovery chain, mutable n8n `latest`, moving PostgreSQL major tag, and unbounded Docker `json-file` logs.

## PROD-H2 — COMPLETE

### Recovery correctness — PASS

Protected production backup created and verified. Backup set contains:

- MoneyTrack PostgreSQL custom-format dump;
- n8n metadata PostgreSQL custom-format dump;
- n8n persistent recovery-critical state including persisted encryption material;
- protected runtime recovery configuration;
- SHA256 manifest and COMPLETE marker.

Isolated restore rehearsal restored both databases only into temporary PostgreSQL containers with no published host ports. Evidence included:

- backup hash verification PASS;
- MoneyTrack restored schema PASS with 30 tables;
- n8n metadata restored schema PASS with 93 tables;
- restored n8n encryption-key presence PASS without printing the value;
- production MoneyTrack DB, n8n metadata DB and n8n health PASS after rehearsal.

### Recurring recovery — PASS

Installed recovery executables are independent of Git checkout state under `/usr/local/lib/moneytrack/`.

- `moneytrack-backup.timer` — daily protected backup, enabled + active;
- local retention — 14 days;
- `moneytrack-restore-verify.timer` — weekly isolated restore verification, enabled + active;
- both timers use `Persistent=true`.

H-01 is closed. Local recovery correctness and recurring local recovery operations are proven.

## PROD-H3 — COMPLETE

### Accepted production runtime

H3 hardened the production runtime through non-secret Compose overlays rather than by rewriting secret-bearing base Compose files.

Permanent operational files:

- `/root/stack/n8n/docker-compose.prod-h.yml`;
- `/opt/moneytrack/postgres/docker-compose.prod-h.yml`;
- `/root/stack/n8n/compose-interpolation.prod-h.sh` mode `600`;
- `/opt/moneytrack/postgres/compose-interpolation.prod-h.sh` mode `600`.

The interpolation snapshot contains only Compose variables required to reproduce the currently-running environment and was captured from live runtime without printing values. It is included in protected recovery archives.

Accepted image policy:

- n8n: `n8nio/n8n@sha256:a49bc161141d6c4b9c495b5a6e3c7c1932e61d2ed2fe3fdca01262064b4b23ca`, runtime `2.22.5`;
- n8n PostgreSQL: `postgres:16.14`;
- MoneyTrack PostgreSQL: `postgres:16.14`.

Accepted Docker log policy on `n8n`, `postgres`, `moneytrack-db`:

```yaml
logging:
  driver: json-file
  options:
    max-size: "10m"
    max-file: "5"
```

### Final H3 cutover evidence — PASS

The accepted wrapped cutover proved, in sequence:

- Compose interpolation context recovered without exposing values;
- candidate Compose render PASS;
- canonical API contract present before mutation;
- rollback images prepared;
- target image versions PASS;
- managed overlays installed and rendered successfully;
- n8n metadata PostgreSQL recreation PASS;
- n8n recreation PASS and API registration PASS;
- MoneyTrack PostgreSQL recreation PASS;
- runtime image/version pins PASS;
- persistent mounts and restart policies preserved;
- complete container environment parity PASS without printing values;
- Docker log rotation PASS on all three containers;
- persisted n8n encryption key remained present;
- API missing-auth contract remained canonical `401 INIT_DATA_MISSING`;
- production health PASS;
- installed recurring backup executable refreshed;
- fresh post-hardening protected backup PASS, including overlays and interpolation snapshots.

The accepted post-hardening backup is `/opt/moneytrack/backups/20260809T145418Z`.

### Preserved failed-attempt evidence

The first H3 cutover attempt reached the post-recreation API smoke too early, received a temporary 404, and automatically rolled back. Subsequent preflights exposed stale rollback provenance and a missing Compose interpolation variable. These were fixed fail-closed before the accepted cutover. Historical evidence is retained in `docs/architecture/PROD-H3-first-cutover-attempt.md`; it does not represent accepted production state.

### H3 debt closed

- H-02 mutable n8n `latest` — CLOSED;
- M-01 unbounded Docker logs — CLOSED;
- M-02 moving PostgreSQL `postgres:16` tag — CLOSED;
- n8n encryption-key persistence — PASS, unchanged;
- Compose recreation context — PROTECTED / REPRODUCIBLE.

## PROD-H4 — CURRENT

H4 is operational hardening only. No new business features, API endpoints or domain changes.

### Read-only operational gate — PASS WITH DEBT REVIEW

The H4 production gate completed with `operational_failures=0` and five warnings.

Confirmed healthy/operational:

- hardened image pins PASS on n8n and both PostgreSQL containers;
- restart policies and log rotation PASS on all three critical containers;
- hardening overlays and protected Compose interpolation snapshots PASS;
- MoneyTrack DB, n8n metadata DB, n8n health and canonical API `401 INIT_DATA_MISSING` smoke PASS;
- daily backup and weekly isolated-restore timers enabled + active;
- latest protected backup hashes and freshness PASS;
- last backup and restore service results PASS;
- root and backup filesystem usage ~24%, PASS;
- certbot timer PASS;
- `n8n.moneytrackapp.xyz` TLS PASS with 77 days remaining at observation time;
- `app.moneytrackapp.xyz` TLS PASS with 81 days remaining at observation time.

Warnings observed:

1. `critical_failed_units` reported an unrelated HabitsTrack restore-verify unit. This is a gate-scoping false positive, not MoneyTrack debt. The H4 gate has been corrected to inspect MoneyTrack-owned/certbot unit names rather than matching generic words in service descriptions.
2. `operator_alerting_hook` — no operator-visible failure hook proved yet.
3. `off_host_backup_path` — no MoneyTrack off-host copy/replication proved yet; AWS CLI and rsync are installed.
4. `backup_failure_domain` — local backup is on the same `/dev/sda1` host/root failure domain.
5. `automation_checkout_drift` — `/home/adm_mt/moneytrack-automation` still has modified `bin/release.sh` and untracked `config/`. This remains MEDIUM operational debt; secret-bearing files must not be committed blindly.

No BLOCKER/HIGH debt was discovered by H4.

### H4 implementation now

- `scripts/prod-h4-external-capability-resolver.sh` performs a narrow read-only resolution of existing AWS/S3 access and operator-notification inputs without printing credential/token/chat values;
- `docs/runbooks/PROD-H-operations.md` now documents the proven runtime/recovery paths, health checks, safe recreation commands, backup-now, isolated restore verification, log policy, TLS checks and recovery-critical file locations;
- if an existing MoneyTrack S3 destination is proved, wire protected backups to it rather than introducing a new storage platform;
- if an existing external notification target is proved, attach MoneyTrack backup/restore/health/TLS failure signals to it;
- if no external destination exists, record off-host durability as an explicitly accepted MEDIUM external-dependency risk rather than pretending same-host backup is disaster recovery.

### Remaining H4 close criteria

H4 closes when:

- false-positive failed-unit warning is gone on the rerun;
- operator alerting is implemented or an explicit accepted residual risk is documented;
- off-host posture is implemented when a usable existing destination is available, otherwise explicitly accepted as MEDIUM external dependency;
- concise operations runbook exists and matches accepted production state.

## PROD-H5 — final gate

Read-only acceptance. PROD-H closes only when:

- no unresolved BLOCKER/HIGH debt remains;
- both PostgreSQL databases have recurring backups and successful isolated restore evidence;
- n8n recovery-critical persistent state is protected;
- runtime image pins and log rotation remain active;
- production recreation path is documented and uses permanent Compose overlays/context files;
- TLS renewal and expiry/failure visibility are operational or residual alerting risk is explicitly accepted;
- critical service health and backup failures can surface to an operator or residual notification risk is explicitly accepted;
- off-host posture is either implemented or explicitly accepted as a remaining MEDIUM external-dependency risk;
- concise operations runbook exists;
- final production gate is green.

## Next

Run the narrow H4 external-capability resolver. Use existing AWS/S3 or alert delivery inputs if present; otherwise record only the specific residual external dependency. Then rerun the operational gate and proceed directly to PROD-H5.
