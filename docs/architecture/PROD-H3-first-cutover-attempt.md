# PROD-H3 — First Runtime Hardening Attempt

## Result

**ROLLED BACK / NO ACCEPTED PRODUCTION CHANGE**

The first PROD-H3 cutover attempt reached the intended runtime hardening state but failed the final API smoke and triggered automatic rollback.

## Evidence before failure

Preflight passed the original gates:

- protected recovery backup and hashes PASS;
- all critical containers running;
- n8n runtime 2.22.5 and PostgreSQL runtimes 16.14;
- Compose provenance PASS;
- restart policy and persistent mount gates PASS;
- candidate image/logging overlay rendered;
- production health PASS.

The preflight also emitted an unresolved Docker Compose interpolation warning:

`HT_SUPPORT_GARAGE_BUCKET variable is not set. Defaulting to a blank string.`

The original gate incorrectly treated that warning as non-blocking.

During the cutover:

- target image versions PASS;
- candidate and installed Compose validation PASS under the original permissive gate;
- n8n PostgreSQL recreation PASS;
- n8n recreation PASS;
- MoneyTrack PostgreSQL recreation PASS;
- runtime pin gate PASS;
- persistence/restart gate PASS;
- Docker log rotation PASS on all three critical containers;
- persisted n8n encryption key remained present.

The immediate API smoke then returned HTTP 404 with `Cannot GET /webhook/api/v1/dashboard` instead of canonical `401 INIT_DATA_MISSING`.

Automatic rollback ran and completed for all three critical containers. Therefore the first attempt is not accepted as the H3 production baseline.

## Root-cause classification

Two harness risks were identified:

1. **Compose interpolation context was not strict enough.** The cutover invoked Compose outside the original stack working directory and tolerated an unset-variable warning. A production recreation gate must not proceed with unresolved interpolation warnings.
2. **n8n `/healthz` is not sufficient proof that production webhooks have finished registering.** The API contract must be polled until the retained webhook returns canonical `401 INIT_DATA_MISSING` or the readiness deadline expires.

The evidence does not prove a MoneyTrack API/domain regression. The intended image pins, persistent mounts and logging policy passed before the API-readiness failure, and rollback completed.

## Retry hardening

The retry harness must:

- run Compose from each container project's original `com.docker.compose.project.working_dir`;
- treat any `variable is not set` interpolation warning as a pre-mutation failure;
- fingerprint container environments before recreation and require exact post-recreation parity without printing values;
- require the retained API contract before mutation;
- after n8n recreation, poll the retained API webhook until canonical `401 INIT_DATA_MISSING`, rather than accepting `/healthz` alone;
- retain automatic rollback for all failures after mutation.

No target runtime policy changes are introduced by this retry.
