# MoneyTrack Production Operations Runbook

## Scope

This runbook covers the current single-host MoneyTrack production runtime after PROD-H hardening. It is operational guidance, not an architecture redesign.

Critical containers:

- `n8n` — n8n runtime, pinned to the accepted immutable 2.22.5 image digest;
- `postgres` — n8n metadata PostgreSQL, pinned to `postgres:16.14`;
- `moneytrack-db` — MoneyTrack PostgreSQL, pinned to `postgres:16.14`.

Critical persistence:

- n8n state: Docker volume `n8n_n8n_data` -> `/home/node/.n8n`;
- n8n metadata DB: Docker volume `n8n_postgres_data`;
- MoneyTrack DB: `/opt/moneytrack/postgres/data`.

Never use `docker compose down -v`, `docker volume rm`, or delete `/opt/moneytrack/postgres/data` during normal restart/recovery work.

## Quick health check

```bash
docker ps --filter name=n8n --filter name=postgres --filter name=moneytrack-db

docker exec moneytrack-db pg_isready -U moneytrack -d moneytrack
docker exec postgres pg_isready -U n8n -d n8n
curl -fsS http://127.0.0.1:5678/healthz

curl -sS -o /tmp/moneytrack-api-smoke.json -w '%{http_code}\n' \
  http://127.0.0.1:5678/webhook/api/v1/dashboard
grep -F '"code":"INIT_DATA_MISSING"' /tmp/moneytrack-api-smoke.json
```

Expected API missing-auth result: HTTP `401` with `INIT_DATA_MISSING`.

## Recovery schedule

```bash
systemctl status moneytrack-backup.timer moneytrack-restore-verify.timer --no-pager
systemctl list-timers --all --no-pager | grep -E 'moneytrack-(backup|restore-verify)\.timer'
```

Policy:

- protected backup daily;
- local retention 14 days;
- isolated restore verification weekly;
- both timers use `Persistent=true`.

Installed recovery executables live under `/usr/local/lib/moneytrack/` and do not depend on the Git checkout.

## Create a protected backup now

```bash
/usr/local/lib/moneytrack/prod-h2-backup-now.sh
```

A successful backup ends with:

```text
backup_result=PASS
=== PROD-H2 BACKUP COMPLETE ===
```

Backup root: `/opt/moneytrack/backups/`.

Each complete recovery point contains database dumps, n8n persistent state, runtime recovery configuration, SHA256 checksums and a `COMPLETE` marker.

## Verify restore without touching production

```bash
/usr/local/lib/moneytrack/prod-h2-restore-verify.sh
```

The verifier restores into temporary PostgreSQL containers with no published host ports. Production databases/volumes are not restore targets.

Expected final marker:

```text
=== PROD-H2 ISOLATED RESTORE VERIFY PASS ===
```

## Recreate n8n stack safely

The base Compose file alone is no longer the complete production definition. Always use the hardening overlay and recovered interpolation context.

```bash
cd /root/stack/n8n
set -a
source ./compose-interpolation.prod-h.sh
set +a

docker compose -p n8n \
  -f docker-compose.yml \
  -f docker-compose.prod-h.yml \
  config >/dev/null

docker compose -p n8n \
  -f docker-compose.yml \
  -f docker-compose.prod-h.yml \
  up -d
```

Then re-run the quick health check.

## Recreate MoneyTrack PostgreSQL safely

```bash
cd /opt/moneytrack/postgres
set -a
source ./compose-interpolation.prod-h.sh
set +a

docker compose -p postgres \
  -f docker-compose.yml \
  -f docker-compose.prod-h.yml \
  config >/dev/null

docker compose -p postgres \
  -f docker-compose.yml \
  -f docker-compose.prod-h.yml \
  up -d
```

Then confirm:

```bash
docker exec moneytrack-db pg_isready -U moneytrack -d moneytrack
```

## Logs

All three critical containers use bounded Docker `json-file` logging:

- `max-size=10m`;
- `max-file=5`.

Inspect recent logs with:

```bash
docker logs --tail 200 n8n
docker logs --tail 200 postgres
docker logs --tail 200 moneytrack-db
```

## TLS

Certbot renewal is timer-driven:

```bash
systemctl status certbot.timer --no-pager
systemctl list-timers --all --no-pager | grep certbot
```

Current public endpoints checked by PROD-H are:

- `n8n.moneytrackapp.xyz`;
- `app.moneytrackapp.xyz`.

The MoneyTrack health monitor treats fewer than 14 certificate days remaining as failure and fewer than 30 days as warning.

## Operator monitoring and durable alert trail

PROD-H4 installs a local operator-visible failure path that does not require an invented external recipient.

Monitor status:

```bash
systemctl status moneytrack-health-monitor.timer moneytrack-health-monitor.service --no-pager
systemctl list-timers --all --no-pager | grep moneytrack-health-monitor
```

The monitor runs approximately every 15 minutes and checks:

- both PostgreSQL readiness checks;
- n8n `/healthz`;
- canonical MoneyTrack API `401 INIT_DATA_MISSING` transport contract;
- backup and restore timers;
- latest protected backup hashes and freshness;
- root filesystem pressure;
- certbot timer;
- live TLS expiry for both public endpoints.

Failures from the health monitor, backup service or restore-verification service invoke the `moneytrack-operator-alert@.service` `OnFailure` hook.

Durable local alert state:

```text
/var/lib/moneytrack/operator-alerts/
```

Inspect it with:

```bash
journalctl -t moneytrack-alert --since today --no-pager
journalctl -u moneytrack-health-monitor.service --since today --no-pager

test -f /var/lib/moneytrack/operator-alerts/latest && \
  cat /var/lib/moneytrack/operator-alerts/latest

test -f /var/lib/moneytrack/operator-alerts/alerts.log && \
  tail -n 50 /var/lib/moneytrack/operator-alerts/alerts.log
```

`UNACKNOWLEDGED` means at least one local alert has not been manually cleared. Remove that marker only after reviewing the relevant service/journal evidence:

```bash
rm -f /var/lib/moneytrack/operator-alerts/UNACKNOWLEDGED
```

External push notification is not assumed. `MONEYTRACK_BOT_TOKEN` exists at runtime, but no operator recipient was proved during PROD-H4, so no Telegram destination was guessed.

## Operational source of truth

Production runtime files are server-local and recovery-protected:

- `/root/stack/n8n/docker-compose.yml`;
- `/root/stack/n8n/docker-compose.prod-h.yml`;
- `/root/stack/n8n/compose-interpolation.prod-h.sh` (`0600`);
- `/opt/moneytrack/postgres/docker-compose.yml`;
- `/opt/moneytrack/postgres/docker-compose.prod-h.yml`;
- `/opt/moneytrack/postgres/compose-interpolation.prod-h.sh` (`0600`);
- `/home/adm_mt/moneytrack-automation/config/n8n.env` where present.

Do not commit secret-bearing server config to Git merely to remove checkout drift.

`/home/adm_mt/moneytrack-automation` currently has known local drift (`bin/release.sh` modified and `config/` untracked). Treat that as operational state until separately reconciled; do not normalize it during incident recovery.

## Controlled residual MEDIUM debt

The non-secret decision record is:

```text
/etc/moneytrack/prod-h4-debt.env
```

Current controlled residual risks:

- off-host backup: not implemented because no usable external destination/identity was proved; local backup remains on the same host failure domain;
- external push alerting: not implemented because no operator recipient was proved; local durable alerting is operational;
- automation checkout drift: documented and intentionally not normalized because `config/` may contain secret-bearing state.

These are MEDIUM operational/external-dependency risks. They are not represented as disaster recovery or external notification coverage.
