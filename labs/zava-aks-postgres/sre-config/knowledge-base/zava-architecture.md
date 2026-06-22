# Zava Athletic — Demo Environment

A Node.js e-commerce app (`zava-storefront` + `zava-api`) on AKS with Azure PostgreSQL Flexible Server. The rest is generic Azure — this file only documents what you can't infer from world knowledge.

## Environment specifics

### How your sandbox reaches things (and what it can't)
You operate with your **own managed identity** (no app credentials, no passwords). Your sandbox reaches the network through an **HTTP(S) egress proxy**: it can reach allow-listed HTTPS endpoints (ARM, Entra, Graph, Azure Monitor, Microsoft Learn) but it **cannot open raw TCP to private VNet IPs** (e.g. PostgreSQL:5432). So you work each surface through a control plane or an in-cluster pod, not a direct socket:

1. **ARM control plane** via `az` (`RunAzCliReadCommands` / `RunAzCliWriteCommands`) — PG state/start/stop/parameters, NSG rules, role lookups, identity, AKS metadata, Azure Monitor.
2. **Kubernetes** via native kubectl tools (`RunKubectlReadCommand` / `RunKubectlWriteCommand` / `RunKubectlCommandHelp`) — first-class kubectl authenticated by your Entra identity (AKS RBAC Cluster Admin). Use them directly for pods, logs, events, deployments, NetworkPolicies.
3. **Terminal** via `RunInTerminal` — `python3`/`node`/scripts inside your sandbox; HTTP(S) egress only (no raw TCP to private IPs). Use it for compute, not for DB or private-service sockets.
4. **PostgreSQL SQL** — because your sandbox can't open a socket to the private DB, run SQL (reads `pg_stat_*`, and read-mostly DDL like `CREATE INDEX CONCURRENTLY` / `ANALYZE`) through the in-cluster helper, which executes from an app pod (a real VNet NIC): `kubectl exec -n zava-demo deploy/zava-api -- node bin/run-sql.js "<SQL>"` (reuses the app pod's PG Entra identity).

Note: do **not** rely on database tools that open their PostgreSQL connection from outside the workload VNet -- they can't reach this private server, and the resulting timeout can be misread as "stopped/network-blocked". Run SQL through the in-cluster helper instead.

### Identities and authorization (already granted — do not try to elevate)
Both SRE Agent identities (system-assigned + UMI `id-sre-agent-*`) hold:
- **Azure Kubernetes Service RBAC Cluster Admin** on the AKS cluster.
- **PostgreSQL Entra admin** (matched by managed-identity *display name*, not client-ID GUID).
- **Reader + Monitoring Reader + Contributor** on the resource group.

The pod's `id-Zava-app-*` identity (used by `bin/run-sql.js`) is also a PG Entra admin. The agent does NOT have `Microsoft.Authorization/roleAssignments/write` and `az role assignment create` will deny.

### App namespace and naming
Namespace `zava-demo`. Deployments `zava-api`, `zava-storefront`. App Insights `cloud_RoleName` is `zava-api`.

## Counterintuitive things (read these — the agent will get them wrong otherwise)

### NSG rules on the PG delegated subnet are platform-managed
Azure Database for PostgreSQL Flexible Server with private access lives in a *delegated* subnet whose routing/policy is managed by the platform ([subnet delegation overview](https://learn.microsoft.com/azure/virtual-network/subnet-delegation-overview), [PG private networking](https://learn.microsoft.com/azure/postgresql/network/concepts-networking-private)). A user-added NSG deny rule covering port 5432 looks like the smoking gun in configuration but is **not** necessarily the active enforcement point.

This AKS cluster has `networkPolicy: 'azure'` enabled, so **Kubernetes NetworkPolicy** is also an enforcement layer for pod-to-PG traffic — verify both surfaces (`az network nsg rule list` and `RunKubectlReadCommand` with `kubectl get networkpolicy -A -o yaml`) before deciding which control is actually carrying the traffic.

### App Insights workspace is shared with the SRE Agent itself
The agent's own ARM-poll telemetry lands in the same workspace with empty `cloud_RoleName` and 100–2000ms durations. **Always filter by `AppRoleName == 'zava-api'`** (KQL) or `cloud/roleName == 'zava-api'` (metrics) when investigating Zava — unfiltered queries are dominated by agent self-noise.

### `/livez` ≠ `/api/health`
`/livez` is shallow liveness (200, no DB call) and is what the K8s liveness probe hits — pods stay alive through DB outages so they can recover without restarting. `/api/health` is the readiness signal and includes a DB ping; expect it to flip to 503 with `db_connected: false` during a DB outage while pods stay `Running`.

### 1 Hz self-probe is expected baseline traffic
Both services run an in-process probe loop (`PROBE_INTERVAL_MS=1000`) hitting `/api/health`, `/api/products`, `/api/products/category/__probe`, and `/livez`. ~60 req/min/pod is synthetic baseline, not load. The slow-query alert KQL excludes the `__probe` path so synthetic traffic doesn't trigger it.

### Slow-query alerts: diagnose at the database, not the cluster
When the App Insights slow-request alert fires (`Zava-products-query-slow`), the bottleneck is almost always at the PostgreSQL layer (missing/disabled index, plan regression, statistics drift), **not** at the pod/CPU/memory layer. Inspect `pg_stat_user_indexes` (low/zero `idx_scan` on a heavily-read table is a strong signal), `pg_stat_user_tables` (high `seq_scan`), and `pg_stat_statements` (top mean-time queries) before looking at AKS resource limits. Run the diagnostic SQL through the in-cluster helper with native kubectl: `kubectl exec -n zava-demo deploy/zava-api -- node bin/run-sql.js "<SQL>"`.

### Metrics are a first-class signal — three views of the same incident
For the slow-query failure mode you have logs, metrics, and traces in the shared workspace, and they corroborate each other: the `AppRequests` log signal (`Zava-products-query-slow`), the app's own custom **metric** `zava.products.category.query.duration_ms` in `AppMetrics` (`Zava-category-latency-metric`), and the `AppDependencies` PostgreSQL-call latency (the trace signal). Treat the metric as primary evidence, not decoration — agreement across all three is what points at the database query rather than pods/CPU/memory.

### PostgreSQL saturation metrics are available
PG Flexible Server platform metrics flow to the workspace via the `AllMetrics` diagnostic setting, queryable in `AzureMetrics` (and surfaced in Metrics Explorer). `cpu_percent`, `active_connections`, `memory_percent`, and IOPS/storage metrics are available for saturation checks. `Zava-db-cpu-saturation` fires on sustained high PG CPU; under a heavy-scan workload it may co-fire with the slow-query signals and corroborates a database-side bottleneck.

### Deployments are an observable signal — correlate 5xx with rollouts
App regressions are often shipped by a deployment, not caused by infra. Every change to the `zava-api` Deployment's pod template (image, env var, config) creates a new ReplicaSet **revision** — that rollout is a first-class signal. When `Zava-http-5xx-errors` fires and the DB/network/slow-query conditions above do NOT correlate, check whether the 5xx onset lines up with a recent rollout: `kubectl rollout history deployment/zava-api -n zava-demo` for the revision list, and `KubeEvents` / `kubectl get events -n zava-demo` for the `ScalingReplicaSet` timestamps. Note that liveness (`/livez`) and readiness (`/api/health`) can stay green through an app-route regression, so the platform looks healthy while the app is broken — deployment correlation is the signal that ties the spike to its cause. The safe remediation for a deploy-induced regression is a rollback to the previous good revision: `kubectl rollout undo deployment/zava-api -n zava-demo`.
