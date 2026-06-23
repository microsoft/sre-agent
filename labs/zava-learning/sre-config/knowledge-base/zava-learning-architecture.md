# Zava Learning — Platform Architecture (SRE Agent knowledge base)

> This document is the SRE Agent's reference for the Zava Learning platform. It describes the
> architecture and the **enforcement surfaces** an investigation must consider. It does **not** name
> the cause of any particular incident — alerts are symptom-only by design, and the agent must
> diagnose root cause from telemetry and live configuration.

## What Zava Learning is

A McGraw-Hill-style online learning platform. Students sign in to a portal, browse courses, and
launch timed quizzes. The student-critical action is **launching a quiz**.

## Topology

```
Internet
  │
  ▼
Application Gateway (Standard_v2, public IP)      ← public entry point
  │   HTTP :80  →  backend probe /health (HTTPS) to the portal
  ▼
[ appgw-subnet 10.20.1.0/24 ]
  │
  ▼   (crosses into the apps subnet)
[ aca-infra-subnet 10.20.2.0/23 ]  — NSG: nsg-aca-*   ← cross-subnet enforcement surface
  │
  ▼
Container Apps environment (internal, VNet-integrated)
  ├─ learner-portal   (external ingress within the VNet; App Gateway backend)
  ├─ course-api       (environment-internal ingress)
  └─ assessment-api   (environment-internal ingress)
```

Quiz launch request path:

```
student → App Gateway → learner-portal → assessment-api → course-api
```

- **learner-portal** serves the UI and proxies `/api/courses` and `/api/quiz/:id`.
- **assessment-api** serves quiz content; it validates the course against **course-api**.
- All services listen on port 8080, exposed by ACA ingress on 80/443.
- App Insights `cloud_RoleName` values: `learner-portal`, `course-api`, `assessment-api`.

## Concrete resource identifiers (this deployment)

These are already resolved for the live environment — use them **directly**; do not run a
lookup to discover them.

- **Log Analytics workspace:** `@@LAW_NAME@@` — workspace **GUID** (pass to `--workspace`): `@@LAW_GUID@@`
- **Application Insights:** `@@APPINSIGHTS_NAME@@` — **App ID** (pass to `--app`): `@@APPINSIGHTS_APPID@@`
- **Container Apps environment:** `@@CAE_NAME@@`
- **Container Registry:** `@@ACR_NAME@@`

When you query telemetry, pass the **identifier above, not the resource name**:

- Log Analytics (`ContainerAppConsoleLogs_CL`, `Syslog`, etc.):
  `az monitor log-analytics query --workspace @@LAW_GUID@@ --analytics-query "<KQL>"`
  `--workspace` requires the **GUID** above — passing the name `@@LAW_NAME@@` returns
  ResourceNotFound, which stalls the investigation awaiting authorization.
- Application Insights (requests/failures/exceptions/dependencies, filtered by `cloud_RoleName`):
  `az monitor app-insights query --app @@APPINSIGHTS_APPID@@ --analytics-query "<KQL>"`

## Data tier (PostgreSQL) — also a failure surface

The quiz lanes are **database-backed**. Quiz content, the question bank, and grading are served from
an **Azure Database for PostgreSQL Flexible Server** that the quiz services read/write on the request
path. A degraded DB surfaces to students as the SAME symptoms as an app fault (slow quiz loading,
intermittent errors under load, "service failing") on an otherwise-clean network/edge path — so when
the edge and replica health are clean, **the database is a surface you must inspect.**

- **Databases:** `zava` (the main quiz database used by most lanes) and `zava_query` (the query lane's
  own database). DB-touching lanes use their own logical database so one lane's DB fault can't starve
  the others.
- **Question bank:** the `question_bank` table (~500k rows) is read on quiz load and is served by the
  index `idx_question_bank_course`. If that index is missing/unusable, the planner falls back to a full
  table scan and quiz loading slows — an index-health problem looks like a latency incident.
- **Connection pool / roles:** quiz services connect through a least-privilege login. The pool lane
  uses the `app_pool` role; a too-low `rolconnlimit` (per-role connection limit) makes connections
  fail intermittently **under load** while a single request still succeeds.
- **Credentials (Key Vault):** each lane reads its DB password from Key Vault (`db-password`,
  `db-pool-password`, and the lane-only `db-password-secretlane`). A rotated/invalid secret surfaces as
  **authentication failures** from that lane only.

Inspect the DB directly with a read-only query (admin password lives in Key Vault `db-password`):

```
srv=$(az postgres flexible-server list -g @@RG@@ --query "[0].name" -o tsv)
usr=$(az postgres flexible-server list -g @@RG@@ --query "[0].administratorLogin" -o tsv)
pw=$(az keyvault secret show --vault-name <kv> --name db-password --query value -o tsv)
az postgres flexible-server execute --name $srv --admin-user $usr --admin-password "$pw" \
  --database-name <zava|zava_query> --querytext "<read-only SQL>"
```

## Enforcement / failure surfaces between the student and a working quiz

There are several independent surfaces; any one can produce the **same** student-facing symptom
("quiz won't launch" / portal errors). The agent must identify **which** from telemetry + config:

1. **Application Gateway** — listener, backend pool, **health probe** (path/host), HTTP settings.
   A probe pointed at a path the portal doesn't serve marks the backend unhealthy → 502s, even though
   the app is fine.
2. **NSG on the apps subnet (`nsg-aca-*`)** — effective inbound rules. NSG rules are evaluated by
   **priority (lowest number wins)**; a high-priority (low-number) DENY can override a lower-priority
   ALLOW (priority inversion) and silently block App Gateway → apps traffic.
3. **Container Apps ingress / internal load balancer** — the environment's internal LB and per-app
   ingress. Revisions and replica health live here.
4. **Application tier** — `course-api` / `assessment-api` themselves: replica count (an API scaled to
   zero answers nothing), exceptions, latency.
5. **Data tier (PostgreSQL)** — the quiz database the services read on the request path: index health
   on `question_bank` (a missing index → full-scan latency), per-role connection limits (pool
   exhaustion → errors under load), and the lane's Key Vault DB secret (a rotated/invalid value →
   authentication failures). A clean edge + healthy replicas with DB-shaped app errors points here.

## Identities and permitted actions

The agent's managed identities have **Reader + Monitoring Reader + Contributor** on the lab resource
group — enough to read telemetry/config and to remediate (delete an NSG rule, correct an App Gateway
probe, restart/scale a Container App). The agent does **not** have `roleAssignments/write`; never
attempt `az role assignment create`.

## Incident lifecycle in this lab

- Alerts are **symptom-only** (e.g. `Zava-quiz-launch-failing`, `Zava-portal-5xx-elevated`). They never
  name NSG/LB/AppGW/app — that's the diagnosis.
- Incidents are managed in **PagerDuty**: Azure Monitor raises the PagerDuty incident; the agent
  acknowledges, annotates with the RCA, and resolves it on recovery.
- For Infrastructure-as-Code or application root causes, the agent opens a **GitHub pull request** with
  the fix and raises a **ServiceNow Change Request** referencing the PR, attaching the RCA.

## Verification after remediation

Re-check the surface you changed, confirm the public endpoint returns 200 on `/` and `/api/quiz/*`,
and confirm the alert/incident auto-mitigated.
