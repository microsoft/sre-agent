---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: performance-investigation
description: Use for Zava Learning incidents where the platform is reachable but a compute tier is degraded — elevated 5xx from the APIs, slow quiz responses, exceptions, an API with no healthy instances, or a back-office batch job failing on the reporting-worker VM (e.g. nightly grade exports). Diagnoses from Application Insights / Log Analytics / Syslog and remediates the application or worker tier.
tools:
  - RunAzCliReadCommands
  - RunAzCliWriteCommands
  - GetAzCliHelp
  - SearchMemory
  - ExecutePythonCode
  - microsoft-learn_microsoft_docs_search
  - microsoft-learn_microsoft_docs_fetch
---

## Zava Learning — Application Incident Runbook

Resource Group: `@@RG@@`. Services (Container Apps): `learner-portal`, `course-api`, `assessment-api`.
Quiz launch path: portal -> assessment-api -> course-api.

Confirm the network/edge is healthy first (App Gateway backend healthy, NSG clean) so you don't
misattribute an app fault. Then:

1. Query App Insights failures/exceptions filtered by the failing `cloud_RoleName`.
2. Check Container App revision health and replica counts — an API with zero replicas serves no
   requests and surfaces as quiz launch / 502 failures with a clean network path. A revision can hit
   zero replicas two ways: scaled to zero, OR the active revision was **deactivated** (an inactive
   revision runs zero replicas). `az containerapp revision list` shows only ACTIVE revisions, so a
   deactivated lane looks like it has "no revisions" — list with `--all` and inspect
   `properties.active` / `properties.latestRevisionName`. The latent cause is often a scale floor of
   zero in IaC (`appLaneMinReplicas: 0`); the durable fix restores a non-zero minimum.
3. Inspect recent revisions/config changes.
4. For LATENCY regressions (slow quiz responses / the latency alert) on a clean network path: pull assessment-api request durations from Log Analytics console logs (each request logs `ms=<duration>`), find the step-change in latency and align it to the most recent assessment-api revision/image deployment, then inspect `src/assessment-api/server.js` for expensive synchronous work added on the request path (e.g. a synchronous KDF/crypto call). This is a code regression — mitigate live by rolling back to the prior revision, then fix durably with a code PR.

## Reporting-worker grade-export failures
If the symptom is the nightly grade-export job failing (no quiz/portal impact — this is a back-office
batch job on a dedicated VM `vm-zava-reporting-*`):
1. Query Log Analytics `Syslog` for `ProcessName == "zava-export"` — the worker logs a heartbeat on
   success and a `FAILED` line plus the raw OS error (`export write error: ...`) on failure. Read the
   raw error to identify the failure mode.
2. Correlate with disk telemetry: the `Perf` table carries Logical Disk `% Used Space` and
   `Free Megabytes` for the worker. A data volume (`/data`) at ~100% used / near-zero free is the
   signal that the export writes are failing for lack of space.
3. Confirm on the VM with a read command (`az vm run-command invoke ... --scripts "df -h /data"`).
4. Mitigate live: free space on the worker's data disk (remove the accumulated backlog file under
   `/data/exports`) via `az vm run-command`. Re-check that the next export run logs a success heartbeat.
5. Durable fix: the worker's export retention/rotation lives in `src/reporting-worker/cloud-init.yaml`
   — a PR that enforces retention (or grows the data disk in `infra/modules/vm.bicep`) is the lasting fix.

## Database-backed quiz lanes (slow loading / errors under load / auth failures)
The quiz lanes read PostgreSQL on the request path, so a DB fault produces app-shaped symptoms on a
clean edge + healthy replicas. Do NOT stop at "the DB looks slow" and report root cause unknown —
identify WHICH database surface — log-first, confirm from the lane's error `detail`, then optionally
verify in the database:
1. Read the quiz service's console logs (`ContainerAppConsoleLogs_CL` for the failing `quiz-*` app /
   `assessment-api`) for the request shape: a slow `ms=<duration>` on `/quiz/*` → index/latency;
   a burst of `status=500` on `/quiz/*` (and any `pool error:` lines) → a backend DB failure.
2. Get the EXACT backend error straight from the lane — the service returns the underlying Postgres
   error in the response `detail` field (it is NOT written to the logs): `curl` the lane's `/health`
   (returns `503 {"status":"degraded","detail":"<pg error>"}` when the DB path is broken) or
   `/quiz/<courseId>` (`500 {"error":"...","detail":"<pg error>"}`). The `detail` names the cause
   directly — e.g. `password authentication failed` (28P01) → bad DB secret; `too many connections`
   / `remaining connection slots` / connection-limit → pool exhaustion; a slow-but-200 `/quiz` with
   climbing `ms=` → missing index. This needs no DB credentials and is the primary confirmation.
3. Optionally confirm against the database itself with a read-only query (connection recipe in the
   knowledge base — server/login from `az postgres flexible-server list`, admin password from Key
   Vault `db-password`, then `az postgres flexible-server execute --querytext "<SQL>"`):
   - **Slow quiz loading (query lane, db `zava_query`):** check the `question_bank` indexes —
     `SELECT indexname FROM pg_indexes WHERE tablename='question_bank';` and
     `SELECT relname,seq_scan,idx_scan FROM pg_stat_user_tables WHERE relname='question_bank';`.
     A missing index on `question_bank` with seq-scans climbing is the root cause; the durable fix is
     to (re)build it (REINDEX/CREATE INDEX) — delivered as a PR.
   - **Errors under load (pool lane, db `zava`):** check the connecting role's connection limit —
     `SELECT rolname,rolconnlimit FROM pg_roles WHERE rolname='app_pool';` and live connections in
     `pg_stat_activity`. A `rolconnlimit` of 1 (or far below the pool size) is the root cause; restore
     a sane limit (`ALTER ROLE app_pool CONNECTION LIMIT <n>`).
   - **Authentication errors (secret lane):** the lane's Key Vault DB secret (`db-password-secretlane`)
     was rotated to an invalid value — confirm the auth-failure log signature; the fix is to **restore a
     valid value INTO `db-password-secretlane`** (copy it from the baseline `db-password` secret with
     `az keyvault secret set`) and then force the lane to re-read it by **creating a NEW revision**
     (`az containerapp update --set-env-vars FORCE_ROTATE=<timestamp>`). A plain `az containerapp
     revision restart` is NOT enough — Container Apps resolve Key Vault secret references at
     revision-creation time, so a restart reuses the cached (still-invalid) value; only a new revision
     re-reads the secret. Then re-check the lane returns 200. Do **NOT** run `az containerapp secret set` /
     re-assert the secret's `identityref` (unnecessary — the reference is already correct), and do **NOT**
     repoint `pg-password` to a different Key Vault secret (e.g. the shared `db-password`) — that masks the
     fault and breaks lane isolation; only the `db-password-secretlane` **value** should change.
4. Mitigate live with the smallest corrective action (rebuild the index / restore the connection limit
   / restore the secret), re-check the lane returns 200, then deliver the durable fix as a PR.
Base the RCA on the confirmed surface above — DB-internal faults must resolve to a named cause (index,
connection limit, or secret), never "root cause unknown."

## Permitted autonomous actions
- Restore replica counts / restart a Container Apps revision.
- Reactivate a deactivated revision (`az containerapp revision activate`) to bring back zero-replica lanes.
- Roll back to the last-known-good revision.
- Free space on the reporting-worker VM's data disk (remove an accumulated backlog file under `/data`).

## Code fix
If the root cause is in application source, the app code lives under `src/` in `@@REPO@@`. After
the live mitigation (revision rollback/restart), the durable code fix is delivered as a GitHub PR
by the `pr-delivery` skill and recorded as a Change Request by `servicenow-change-management`.

## Incident communication
PagerDuty acknowledgement, status/summary notes, and resolution are owned by the
`pagerduty-incident-update` skill.

## Verification
Confirm `/api/quiz/*` returns 200 and the API success rate is back to baseline.
