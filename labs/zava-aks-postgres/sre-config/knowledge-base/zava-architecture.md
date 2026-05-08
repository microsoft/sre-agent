# Zava Athletic — Demo Environment

A Node.js e-commerce app (`zava-storefront` + `zava-api`) on AKS with Azure PostgreSQL Flexible Server. The rest is generic Azure — this file only documents what you can't infer from world knowledge.

## Environment specifics

### You are outside this VNet
The agent runtime has no network path to the AKS API server (private cluster, no public FQDN) or PostgreSQL (`publicNetworkAccess: Disabled`, port 5432 unreachable). Direct TCP probes, raw `kubectl --server=...`, `psql`, and `az postgres flexible-server execute` will all fail or be unavailable — that is the network, not a permissions problem.

Everything goes through `az`:

1. **ARM control plane** for everything ARM exposes (PG state, NSG rules, role lookups, identity, AKS metadata).
2. **`az aks command invoke`** for in-cluster operations. Pass kubectl args as the `--command` payload; the proxy runs them inside the cluster network. This is your only path to the cluster's API server.
3. **`bin/run-sql.js` exec'd through `az aks command invoke`** — the only path to PostgreSQL. Helper baked into the `zava-api` container, single SQL statement as its only argv, runs under the pod's workload identity (`DefaultAzureCredential` + `ossrdbms-aad`), prints `JSON.stringify(rows || command)`. The command shape is:
   ```
   az aks command invoke -g <rg> -n <aks> --command \
     "kubectl exec -n zava-demo deploy/zava-api -- node bin/run-sql.js \"<SQL>\""
   ```

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

This AKS cluster has `networkPolicy: 'azure'` enabled, so **Kubernetes NetworkPolicy** is also an enforcement layer for pod-to-PG traffic — verify both surfaces (`az network nsg rule list` and `az aks command invoke … kubectl get networkpolicy -A -o yaml`) before deciding which control is actually carrying the traffic.

### App Insights workspace is shared with the SRE Agent itself
The agent's own ARM-poll telemetry lands in the same workspace with empty `cloud_RoleName` and 100–2000ms durations. **Always filter by `AppRoleName == 'zava-api'`** (KQL) or `cloud/roleName == 'zava-api'` (metrics) when investigating Zava — unfiltered queries are dominated by agent self-noise.

### `/livez` ≠ `/api/health`
`/livez` is shallow liveness (200, no DB call) and is what the K8s liveness probe hits — pods stay alive through DB outages so they can recover without restarting. `/api/health` is the readiness signal and includes a DB ping; expect it to flip to 503 with `db_connected: false` during a DB outage while pods stay `Running`.

### 1 Hz self-probe is expected baseline traffic
Both services run an in-process probe loop (`PROBE_INTERVAL_MS=1000`) hitting `/api/health`, `/api/products`, `/api/products/category/__probe`, and `/livez`. ~60 req/min/pod is synthetic baseline, not load. The slow-query alert KQL excludes the `__probe` path so synthetic traffic doesn't trigger it.

### Slow-query alerts: diagnose at the database, not the cluster
When the App Insights slow-request alert fires (`Zava-products-query-slow`), the bottleneck is almost always at the PostgreSQL layer (missing/disabled index, plan regression, statistics drift), **not** at the pod/CPU/memory layer. Inspect `pg_stat_user_indexes` (low/zero `idx_scan` on a heavily-read table is a strong signal), `pg_stat_user_tables` (high `seq_scan`), and `pg_stat_statements` (top mean-time queries) before looking at AKS resource limits. Use the `bin/run-sql.js` invocation pattern from above to run the diagnostic SQL.
