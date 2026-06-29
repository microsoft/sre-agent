# Zava Athletic — Demo Environment

A Node.js e-commerce app (`zava-storefront` + `zava-api`) on AKS with Azure PostgreSQL Flexible Server. The rest is generic Azure — this file only documents what you can't infer from world knowledge.

## Environment specifics

### How your sandbox reaches things (and what it can't)
You operate with your **own managed identity** (no app credentials, no passwords). Your sandbox egress is forced through an Azure Firewall (allow-list: ARM, Entra, Graph, Microsoft Learn) **and a TLS-inspecting forward proxy** that re-signs certificates. The firewall ALSO permits the agent subnet to reach the AKS API server (so you **can use native `kubectl`**). Azure Monitor is **private-only by default**: the public `AzureMonitor` tag is dropped and your Monitor DNS resolves to the AMPLS private endpoint, but your Log Analytics / Application Insights query tools work normally over it — just query as usual. Surfaces:

1. **ARM control plane** via `az` (`RunAzCliReadCommands` / `RunAzCliWriteCommands`) — PG state/start/stop/parameters, NSG rules, role lookups, identity, AKS metadata, Azure Monitor.
2. **Kubernetes** via NATIVE `kubectl` (`RunKubectlReadCommand` / `RunKubectlWriteCommand`), authenticated by your Entra identity (AKS RBAC Cluster Admin). One-time setup per session: (a) `az aks get-credentials -g @@RG@@ -n <aks> --overwrite-existing`; (b) `kubelogin convert-kubeconfig -l azurecli` (non-interactive managed-identity auth — the default device-code flow hangs); (c) merge the egress-proxy CA `/etc/ssl/certs/adc-egress-proxy-ca.crt` into the kubeconfig cluster's `certificate-authority-data` so kubectl trusts the re-signed TLS. Then use kubectl directly for pods, logs, events, deployments, NetworkPolicies, rollouts. `az aks command invoke -g @@RG@@ -n <aks> --command "kubectl …"` is a fallback.
3. **Terminal** via `RunInTerminal` — `python3`/`node`/scripts inside your sandbox; egress is the same firewalled allow-list. Use it for compute, not for opening DB sockets directly.
4. **PostgreSQL SQL** — run SQL (reads `pg_stat_*`, and read-mostly DDL like `CREATE INDEX CONCURRENTLY` / `ANALYZE`) through the in-cluster helper from an app pod (a real VNet NIC): `kubectl exec -n zava-demo deploy/zava-api -- node bin/run-sql.js '<SQL>'` (reuses the app pod's PG Entra identity).

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

### Slow-query alerts: diagnose at the database, not the cluster
When the App Insights slow-request alert fires (`Zava-products-query-slow`), the bottleneck is almost always at the PostgreSQL layer (missing/disabled index, plan regression, statistics drift), **not** at the pod/CPU/memory layer. Inspect `pg_stat_user_indexes` (low/zero `idx_scan` on a heavily-read table is a strong signal), `pg_stat_user_tables` (high `seq_scan`), and `pg_stat_statements` (top mean-time queries) before looking at AKS resource limits. Run the diagnostic SQL through the in-cluster helper: `kubectl exec -n zava-demo deploy/zava-api -- node bin/run-sql.js "<SQL>"`.

### Metrics are a first-class signal — three views of the same incident
For the slow-query failure mode you have logs, metrics, and traces in the shared workspace, and they corroborate each other: the `AppRequests` log signal (`Zava-products-query-slow`, the one dispatching alert), the app's own custom **metric** `zava.products.category.query.duration_ms` in `AppMetrics`, and the `AppDependencies` PostgreSQL-call latency (the trace signal). You **query** the metric and trace as corroboration — they're paired with the alert, not separate dispatching alerts. Treat the metric as primary evidence, not decoration — agreement across all three is what points at the database query rather than pods/CPU/memory.

### PostgreSQL saturation metrics are available
PG Flexible Server platform metrics flow to the workspace via the `AllMetrics` diagnostic setting, queryable in `AzureMetrics` (and surfaced in Metrics Explorer). `cpu_percent`, `active_connections`, `memory_percent`, and IOPS/storage metrics are available for saturation checks. Under a heavy-scan (missing-index) workload `cpu_percent` climbs and corroborates a database-side bottleneck — query it during slow-query investigation.

### Deployments are an observable signal — correlate 5xx with rollouts
App regressions are often shipped by a deployment, not caused by infra. Every change to the `zava-api` Deployment's pod template (image, env var, config) creates a new ReplicaSet **revision** — that rollout is a first-class signal. When `Zava-http-5xx-errors` fires and the DB/network/slow-query conditions above do NOT correlate, check whether the 5xx onset lines up with a recent rollout: `kubectl rollout history deployment/zava-api -n zava-demo` for the revision list, and `KubeEvents` / `kubectl get events -n zava-demo` for the `ScalingReplicaSet` timestamps. Note that liveness and readiness (`/livez`) can stay green through an app-route regression, so the platform looks healthy while the app is broken; `/api/health` is an application health endpoint and can also stay green for app-route-only failures — deployment correlation is the signal that ties the spike to its cause. The safe remediation for a deploy-induced regression is a rollback to the previous good revision: `kubectl rollout undo deployment/zava-api -n zava-demo`.

## Hub-and-spoke network and the hub firewall

You run VNet-injected in your **own spoke** (`vnet-Zava-agent-*`, `agent-subnet` 10.30.0.0/27), with all egress forced through a **shared Azure Firewall in the hub** (`vnet-Zava-hub-*`) over VNet peering. The workload — AKS and PostgreSQL — sits in a separate **platform spoke** (`vnet-Zava-platform-*`). Your agent subnet is pinned to **your own region** (VNet injection is regional — the subnet must be in the same region as you), but that only fixes *where you run*, not *what you can reach*: peering lets you operate on resources in **other Azure regions** (global VNet peering) or **on-prem** (ExpressRoute/VPN) too — here everything you act on is co-regional, so no cross-region hop is needed. Nothing about how you operate changes: you reach the private AKS API server through native `kubectl` (with `az aks command invoke` as fallback), PostgreSQL through the in-cluster `bin/run-sql.js` helper, ARM / Entra / Microsoft Learn over allow-listed HTTPS, and Azure Monitor (Log Analytics / App Insights) over the AMPLS private endpoint by default — all through the hub firewall, and your Monitor query tools work normally over the private path. You never need raw L3 reachability to the other spokes.

When an incident has a network/egress dimension, the **hub Azure Firewall is itself an inspectable resource**: read its policy and rule collections over ARM (your Reader role covers `az network firewall [policy] show`), and see what it actually allowed or denied in the resource-specific **`AZFW*`** Log Analytics tables (`AZFWNetworkRule`, `AZFWApplicationRule`, `AZFWNatRule`, `AZFWDnsQuery`) — those tables exist because the firewall's diagnostic setting uses the `Dedicated` destination. There is no third-party network device in this environment, and your sandbox egress is allow-listed HTTPS only, so you cannot open a raw TCP/SSH socket to a device IP; a device's own telemetry (if one shipped syslog/CEF to this workspace) would be the path, never a direct connection.

**Scope the firewall correctly when diagnosing.** It gates **your** egress only — it is **NOT** in the app→PostgreSQL path. AKS and PostgreSQL share the platform spoke and talk to each other directly (their subnets are not forced through the firewall), so for the app's DB-connectivity / network-partition incidents the enforcement points are the **platform-spoke NSG** and the **in-cluster Kubernetes NetworkPolicy** — not the hub firewall. Treat the firewall as a diagnostic surface for **your own** reachability (e.g., an ARM / Azure Monitor / Microsoft Learn call that is refused or times out), and don't pin an app DB outage on it.
