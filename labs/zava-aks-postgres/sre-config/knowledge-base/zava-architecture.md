# Zava Athletic — Demo Environment

A Node.js e-commerce app (`zava-storefront` + `zava-api`) on AKS with Azure PostgreSQL Flexible Server. The rest is generic Azure — this file only documents what you can't infer from world knowledge.

## Environment specifics

### How your sandbox reaches things (and what it can't)
You operate with your **own managed identity** (no app credentials, no passwords). Your sandbox egress is forced through an Azure Firewall (allow-list: ARM, Entra, Graph, Microsoft Learn). Azure Monitor is **private-only by default**: the public `AzureMonitor` tag is dropped and your Monitor DNS resolves to the AMPLS private endpoint, but your Log Analytics / Application Insights query tools work normally over it — just query as usual. Surfaces:

1. **ARM control plane** via `az` (`RunAzCliReadCommands` / `RunAzCliWriteCommands`) — PG state/start/stop/parameters, NSG rules, role lookups, identity, AKS metadata, Azure Monitor.
2. **Kubernetes** via the built-in `RunKubectlReadCommand` and `RunKubectlWriteCommand` system tools; they accept the same kubectl commands as a terminal. Incident runbooks use these tools directly rather than setting up terminal-native kubectl.
3. **PostgreSQL SQL** — use `RunKubectlWriteCommand` to run SQL (reads `pg_stat_*`, and read-mostly DDL like `CREATE INDEX CONCURRENTLY` / `ANALYZE`) through the in-cluster helper from an app pod: `kubectl exec -n zava-demo deploy/zava-api -- node bin/run-sql.js '<SQL>'` (reuses the app pod's PG Entra identity).

Note: do **not** rely on database tools that open their PostgreSQL connection from outside the platform-spoke VNet (where PostgreSQL lives) -- they can't reach this private server, and the resulting timeout can be misread as "stopped/network-blocked". Run SQL through the in-cluster helper instead.

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

This AKS cluster has `networkPolicy: 'azure'` enabled, so **Kubernetes NetworkPolicy** is also an enforcement layer for pod-to-PG traffic — verify both surfaces (`az network nsg rule list` and `kubectl get networkpolicy -A -o yaml`) before deciding which control is actually carrying the traffic.

### App Insights workspace is shared with the SRE Agent itself
The agent's own ARM-poll telemetry lands in the same workspace with empty `cloud_RoleName` and 100–2000ms durations. **Always filter by `AppRoleName == 'zava-api'`** (KQL) or `cloud/roleName == 'zava-api'` (metrics) when investigating Zava — unfiltered queries are dominated by agent self-noise.

### `/livez` ≠ `/api/health`
`/livez` is shallow liveness (200, no DB call) and is what the K8s liveness and readiness probes hit — pods stay alive and Ready through DB outages so they can recover without restarting. `/api/health` is an application health endpoint that includes a DB ping; expect it to flip to 503 with `db_connected: false` during a DB outage while pods stay `Running`/`Ready`.

### 1 Hz self-probe is expected baseline traffic
Both services run an in-process probe loop (`PROBE_INTERVAL_MS=1000`) hitting `/api/health`, `/api/products`, `/api/products/category/__probe`, and `/livez`. ~60 req/min/pod is synthetic baseline, not load. The slow-query alert KQL excludes the `__probe` path so synthetic traffic doesn't trigger it.

### Slow-query alerts: inspect the database query path
When `Zava-products-query-slow` fires, inspect PostgreSQL indexes, scan activity,
statements, and query plans before changing AKS capacity. Run diagnostic SQL through
the in-cluster helper: `kubectl exec -n zava-demo deploy/zava-api -- node bin/run-sql.js "<SQL>"`.

### Metrics are a first-class signal — three views of the same incident
For the slow-query failure mode you have logs, metrics, and traces in the shared workspace, and they corroborate each other: the `AppRequests` log signal (`Zava-products-query-slow`, the one dispatching alert), the app's own custom **metric** `zava.products.category.query.duration_ms` in `AppMetrics`, and the `AppDependencies` PostgreSQL-call latency (the trace signal). You **query** the metric and trace as corroboration — they're paired with the alert, not separate dispatching alerts. Treat the metric as primary evidence, not decoration — agreement across all three is what points at the database query rather than pods/CPU/memory.

### PostgreSQL saturation metrics are available
PG Flexible Server platform metrics flow to the workspace via the `AllMetrics` diagnostic setting, queryable in `AzureMetrics` (and surfaced in Metrics Explorer). `cpu_percent`, `active_connections`, `memory_percent`, and IOPS/storage metrics are available for saturation checks. Under a heavy-scan (missing-index) workload `cpu_percent` climbs and corroborates a database-side bottleneck — query it during slow-query investigation.

### Deployments are an observable signal
Each change to the `zava-api` pod template creates a ReplicaSet revision. When
`Zava-http-5xx-errors` fires, compare the 5xx onset with `kubectl rollout history`
and `ScalingReplicaSet` events. Liveness, readiness, and `/api/health` can remain
healthy during a route-specific regression. When the rollout evidence establishes
the cause, restore the previous revision with
`kubectl rollout undo deployment/zava-api -n zava-demo`.

## Hub-and-spoke network and the hub firewall

You run VNet-injected in your **own spoke** (`vnet-Zava-agent-*`, `agent-subnet` 10.30.0.0/27), with all egress forced through a **shared Azure Firewall in the hub** (`vnet-Zava-hub-*`) over VNet peering. The workload — AKS and PostgreSQL — sits in a separate **platform spoke** (`vnet-Zava-platform-*`). Your agent subnet is pinned to **your own region** (VNet injection is regional — the subnet must be in the same region as you), but that only fixes *where you run*, not *what you can reach*: peering lets you operate on resources in **other Azure regions** (global VNet peering) or **on-prem** (ExpressRoute/VPN) too — here everything you act on is co-regional, so no cross-region hop is needed. Use the built-in Kubernetes system tools for cluster operations; use ARM / Entra / Microsoft Learn over allow-listed HTTPS and Azure Monitor over the AMPLS private endpoint by default.

When an incident has a network/egress dimension, the **hub Azure Firewall is itself an inspectable resource**: read its policy and rule collections over ARM (your Reader role covers `az network firewall [policy] show`), and see what it actually allowed or denied in the resource-specific **`AZFW*`** Log Analytics tables (`AZFWNetworkRule`, `AZFWApplicationRule`, `AZFWNatRule`, `AZFWDnsQuery`) — those tables exist because the firewall's diagnostic setting uses the `Dedicated` destination. There is no third-party network device in this environment, and your sandbox egress is allow-listed HTTPS only, so you cannot open a raw TCP/SSH socket to a device IP; a device's own telemetry (if one shipped syslog/CEF to this workspace) would be the path, never a direct connection.

**Scope the firewall correctly when diagnosing.** It gates **your** egress only — it is **NOT** in the app→PostgreSQL path. AKS and PostgreSQL share the platform spoke and talk to each other directly (their subnets are not forced through the firewall), so for the app's DB-connectivity / network-partition incidents the enforcement points are the **platform-spoke NSG** and the **in-cluster Kubernetes NetworkPolicy** — not the hub firewall. Treat the firewall as a diagnostic surface for **your own** reachability (e.g., an ARM / Azure Monitor / Microsoft Learn call that is refused or times out), and don't pin an app DB outage on it.
