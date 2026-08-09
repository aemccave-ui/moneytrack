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

Remaining known debt entering H4:

- **M-03 — automation checkout drift:** `/home/adm_mt/moneytrack-automation` previously showed modified `bin/release.sh` and untracked `config/`; secret-bearing files must not be committed blindly;
- **M-04 — alerting visibility:** certbot renewal exists, but operator-visible failure/expiry alerting is not yet proved;
- **M-05 — off-host durability:** current backup correctness is local; off-host copy/replication is not yet proved.

### H4 operational gate

`scripts/prod-h4-operational-gate.sh` is read-only. It checks:

1. hardened image pins, restart policies, overlays, Compose-context snapshots and log rotation;
2. n8n / both PostgreSQL databases / canonical API transport health;
3. backup and restore timers, latest backup hashes/freshness and service-result state;
4. disk usage, certbot timer and live TLS certificate expiry;
5. existing operator alerting hooks without printing secret-bearing command content;
6. existing off-host evidence such as remote mounts or MoneyTrack sync/upload units;
7. whether backup storage shares the host/root failure domain;
8. automation checkout drift filenames only.

Absence of alerting or off-host evidence is reported as WARN rather than hidden. A real health/runtime/recovery failure is blocking.

### H4 implementation rule

After the read-only gate:

- if operator alerting already exists and is credible, document it rather than replacing it;
- otherwise implement one minimal failure-notification path for backup, restore verification, service health, disk and certificate expiry;
- if a usable off-host destination already exists, attach MoneyTrack protected backups to it with bounded retention/verification;
- if no destination exists, record that external dependency explicitly and do not pretend same-host storage is disaster recovery;
- produce a concise operational runbook covering deploy/recreate, restart, rollback, backup, isolated restore, health checks and recovery-critical file locations.

## PROD-H5 — final gate

Read-only acceptance. PROD-H closes only when:

- no unresolved BLOCKER/HIGH debt remains;
- both PostgreSQL databases have recurring backups and successful isolated restore evidence;
- n8n recovery-critical persistent state is protected;
- runtime image pins and log rotation remain active;
- production recreation path is documented and uses permanent Compose overlays/context files;
- TLS renewal and expiry/failure visibility are operational;
- critical service health and backup failures can surface to an operator;
- off-host posture is either implemented or explicitly accepted as a remaining MEDIUM external-dependency risk;
- concise operations runbook exists;
- final production gate is green.

## Next

Run the PROD-H4 read-only operational gate. Use its output to implement only the missing alerting/off-host/runbook pieces, then proceed directly to PROD-H5.
