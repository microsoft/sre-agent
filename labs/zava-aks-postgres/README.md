# SRE Agent Demo — Zava Athletic

An AI-first demo showing Azure SRE Agent autonomously detecting and fixing infrastructure issues. Clone it, ask your AI assistant to set it up, break stuff, watch the agent fix it.

## AI-First Setup

This repo is designed to be deployed by an AI agent (Copilot CLI, VS Code Copilot, Claude, etc.). Clone it and ask:

> "Set up this demo for me"

The agent reads `AGENTS.md` and the skills in `.github/skills/` to handle everything — `azd up`, SRE Agent configuration, browser verification. No manual command typing.

Or do it yourself:
```bash
azd up                       # Deploy everything (~25 min)
azd down --force --purge     # Tear down when done
```

## What You Get

| Component | Details |
|-----------|---------|
| **App** | Zava Athletic e-commerce storefront (Node.js/Express on AKS) |
| **Database** | PostgreSQL 16 Flexible Server (Entra-only auth, zero passwords) |
| **Monitoring** | App Insights + Log Analytics (4-day retention on noisy tables, no daily ingestion cap, 100% sampling; probes filtered at the alert KQL so alerts fire fast) + **3 enabled dispatching Azure Monitor alerts**: `postgres-unreachable` (covers both DB-stop and network-partition scenarios), `Zava-products-query-slow`, and `Zava-http-5xx-errors`, so one root cause = one incident thread. The app emits a **custom OpenTelemetry metric** (`zava.products.category.query.duration_ms`) and PG emits `cpu_percent`; the slow-query alert is **paired** with both as corroboration the agent queries during investigation (kept as *disabled* metric-alert examples rather than separate dispatching alerts, to avoid duplicate threads). |
| **SRE Agent** | Anthropic-backed agent (Preview channel). Connectors, skills, response plans, and Azure Monitor incident binding declared in `infra/modules/sre-agent.bicep`. Knowledge-file upload via `scripts/setup-sre-agent.ps1` (ARM doesn't surface that yet). Default agent + rich skills, no subagent handoff. |
| **Telemetry access** | App Insights, Log Analytics, and Azure Monitor exposed via **connectors** |
| **Demo Scenarios** | 4 break/fix scenarios with scripts |

## Architecture

```
Azure Resource Group (single RG — `azd down` cleans everything)

HUB VNet  10.10.0.0/22   (shared edge / security)
  ├─ Azure Firewall — the agent's single egress point AND the "network device"
  │    it interrogates: read its policy/rules over ARM, query AZFW* logs via KQL
  ├─ GatewaySubnet      (reserved → ExpressRoute / VPN gateway to on-prem)
  └─ Private Endpoint → Azure Monitor Private Link Scope (AMPLS)
        ▲                                         ▲
        │ peering                                 │ peering + UDR (forced tunnel)
        │                                         │
  PLATFORM spoke  10.20.0.0/16            AGENT spoke  10.30.0.0/24
    ├─ AKS (private API server)             └─ SRE Agent (VNet-injected)
    │    ├─ zava-storefront                      • reaches AKS via native kubectl + ARM
    │    └─ zava-api  ──►  PostgreSQL 16           (native kubectl exec, run-sql.js)
    └─ db-subnet (delegated)   (Entra auth)      • all egress → hub firewall only

App Insights + Log Analytics   (AppRequests, AppMetrics, AZFW* firewall logs, KubeEvents …)
```

## What it looks like

The storefront is a normal e-commerce app — when the backend breaks, the UI degrades visibly so the audience can see the failure without reading logs.

| Healthy | Broken (Scenario 1 — PostgreSQL stopped) |
|---|---|
| ![Healthy storefront](docs/images/storefront-healthy.png) | ![Broken storefront](docs/images/storefront-broken.png) |
| `ALL SYSTEMS OPERATIONAL` · 50 products · ~1 ms DB response | `SERVICE DISRUPTION` · 503 · `database unreachable` · `agent investigating` |

While the UI shows `agent investigating`, the SRE Agent is actually working the incident in the Azure portal — investigating telemetry, picking a runbook, and (with autonomous mode + High access enabled by Bicep) executing the fix. Screenshot of an agent thread resolving Scenario 1 goes here:

![SRE Agent resolving the incident](docs/images/agent-resolving.png)

## Demo Scenarios

### Scenario 1: Database Outage
```powershell
.\.github\skills\running-demo\scripts\break-sql.ps1    # Stops PostgreSQL → 503 errors
# Agent detects via Azure Monitor, investigates, restarts PostgreSQL
.\.github\skills\running-demo\scripts\fix-sql.ps1      # Fallback if agent doesn't fix
```

### Scenario 2: Network Partition
```powershell
.\.github\skills\running-demo\scripts\break-network.ps1  # K8s NetworkPolicy blocks DB traffic
# Agent sees ETIMEDOUT (not ECONNREFUSED), finds and removes NetworkPolicy
.\.github\skills\running-demo\scripts\fix-network.ps1    # Fallback
```

### Scenario 3: Missing Index
```powershell
.\.github\skills\running-demo\scripts\break-db-perf.ps1  # Drops category/name index → slow queries
# One alert dispatches (Zava-products-query-slow); the agent then correlates the
# paired signals it queries — the custom metric (zava.products.category.query.duration_ms
# in AppMetrics) + PG cpu_percent (AzureMetrics) + AppDependencies pg-call latency —
# and applies CREATE INDEX via the in-cluster helper. One root cause, one thread.
.\.github\skills\running-demo\scripts\fix-db-perf.ps1    # Fallback
```

### Scenario 4: Bad Deploy / Rollback
```powershell
.\.github\skills\running-demo\scripts\break-bad-deploy.ps1  # kubectl set env FAULT_INJECT=500 → new rollout, GET /api/products returns 500
# Existing Zava-http-5xx-errors alert fires; agent correlates the 5xx spike with the recent
# rollout (kubectl rollout history / KubeEvents) and rolls back to the previous good revision.
.\.github\skills\running-demo\scripts\fix-bad-deploy.ps1    # Fallback: kubectl rollout undo
```
Liveness and readiness (`/livez`) stay green, and `/api/health` can stay healthy for app-only regressions, so the platform looks healthy while
only the app route regresses — deployment-signal correlation is what ties the symptom to its cause.

## SRE Agent Management

Agent configuration is fully declarative in **`infra/modules/sre-agent.bicep`** —
connectors, custom skills, response plans / incident filters, autonomous mode, and Azure
Monitor incident binding all flow through `Microsoft.App/agents/*` ARM resources. To change
them, edit the Bicep and run `azd provision`.

The only data-plane state ARM doesn't yet surface is **knowledge file upload** — handled
by `scripts/setup-sre-agent.ps1`, which also verifies the Bicep-deployed assets are live.
Drop new `*.md` files into `sre-config/knowledge-base/` and re-run the script to sync.

## How the Agent Operates Against a Private Backend

### Network posture: VNet-injected, egress locked down behind an Azure Firewall

The agent is **injected into a dedicated agent spoke VNet** (a delegated `agent-subnet`) and its sandbox egress is **locked down behind an Azure Firewall** — default-deny, with a tight allow-list (ARM, Entra, Microsoft Graph, Azure Monitor, Microsoft Learn, GitHub raw for the Learn MCP server bits) **plus a narrow rule to the AKS API server** that enables native kubectl. The agent sits **inside** the VNet and operates the cluster with **native `kubectl`** (authenticated by its own managed identity) and runs PostgreSQL SQL through an in-cluster pod; `az aks command invoke` remains a fallback. ARM and Azure Monitor go over the control plane; nothing else gets out. The point is a fully locked-down, in-VNet agent: it sits inside the customer network boundary yet its blast radius is constrained to the allow-list and its least-privilege identity grants. See **[Native kubectl (enabled)](#native-kubectl-enabled)** for exactly how the API-server path + auth are wired (and how to close it for a command-invoke-only posture).

> **What "VNet-injected" means here:** the agent's egress mode is **AzureVNet** (real VNet egress) routed through the Azure Firewall **and** a TLS-inspecting forward proxy that re-signs certificates. The firewall allow-list is ARM/Entra/Graph, Azure Monitor, Microsoft Learn (+ GitHub raw for the Learn MCP server bits), **and a rule (with SNAT) to the AKS API server** — so the agent reaches the private API server and uses **native `kubectl`** (managed-identity auth via `kubelogin`, trusting the egress-proxy CA). PostgreSQL SQL runs from an in-cluster pod (a real VNet NIC) via `kubectl exec`. Egress allow/deny decisions are visible in the SRE Agent UI under **Workspace Configuration → Inspect → Network audit** (Preview). To revert to a command-invoke-only, maximally-locked-down posture, remove the API-server firewall rule + SNAT — see [Native kubectl (enabled)](#native-kubectl-enabled).

> **Scope:** the firewall + forced-tunnel route govern the **agent sandbox's internet egress** (the `agent-subnet` only). They do not restrict private intra-VNet traffic, the AKS subnet's own egress, or what the agent can make AKS do via its Cluster Admin RBAC — those are governed by Kubernetes RBAC and the agent's action boundary, not this firewall.

One consequence is worth calling out, because it shapes Scenario 3's remediation: **DDL like `CREATE INDEX` is data-plane only.** No managed PG service (Azure PG Flex, RDS, Cloud SQL) exposes catalog mutation through its cloud control plane. The agent reads `pg_stat_*` to diagnose the missing index and applies the DDL the same way — by running the in-cluster helper from a workload that's already in the VNet (the api pod), reached via native `kubectl exec`:

```
kubectl exec deploy/zava-api -n zava-demo -- node bin/run-sql.js '<SQL>'
```

`bin/run-sql.js` is ~30 lines: a `pg`-client wrapper that reuses the pod's existing workload identity (already a PG Entra admin). No new endpoint, no new identity, no temporary network opening — just reuses an existing trust path.

| Component | Endpoint | How the agent works on it |
|---|---|---|
| Storefront / nginx ingress | Public LoadBalancer IP | HTTP from anywhere |
| AKS API server | **Private** (AKS private-DNS zone linked to the agent VNet; firewall rule + SNAT to the API server) | Native `kubectl`, authenticated by the agent's Entra identity (*Cluster Admin* RBAC); `az aks command invoke` is the fallback |
| Pods, services, node IPs | Private (VNet only) | Native `kubectl <verb>` (`get`, `logs`, `describe`, `delete`, `apply`, `exec`, `rollout`); `az aks command invoke -- kubectl <verb>` remains the fallback |
| PostgreSQL Flex (port 5432) | **Private only** — `publicNetworkAccess: Disabled`, VNet-delegated | State/config: `az postgres flexible-server`. SQL (reads + DDL): native `kubectl exec deploy/zava-api -- node bin/run-sql.js '<SQL>'` — the in-cluster pod (a real VNet NIC) reuses the pod's PG Entra identity; command-invoke is the fallback |

### What the agent can do (from inside the locked-down VNet)

| Plane | Read | Write / remediate |
|---|---|---|
| **AKS control plane** | `az aks show / nodepool list / get-upgrades` | `az aks start / stop / update / nodepool scale / rotate-certs` |
| **Kubernetes (via native `kubectl`)** | `kubectl get … / logs / describe` | `kubectl delete networkpolicy …` (Scenario 2), `kubectl rollout undo …`, `kubectl exec deploy/zava-api -- node bin/run-sql.js 'CREATE INDEX …'` (Scenario 3); `az aks command invoke` remains the fallback |
| **PostgreSQL** | Control: `az postgres flexible-server show / parameter list / backup list / server-logs list / replica list`. Data (reads + DDL): native `kubectl exec … bin/run-sql.js` | `az postgres flexible-server start` (**Scenario 1**), `restart`, `update`, `parameter set`, `replica create`, `restore`, `ad-admin create` |
| **Networking** | `az network nsg / vnet / private-dns show`, plus the hub firewall as a device: `az network firewall [policy] show` (Reader-covered) and its `AZFW*` logs (KQL) | `az network nsg rule create / delete` (Scenario 2 cleanup) |
| **Telemetry** | App Insights, Log Analytics, and Azure Monitor connectors (KQL + metrics) — API-based, no network reachability needed | Alert / action group create / update |

### Running PostgreSQL SQL

SQL — reads (`pg_stat_*`) and read-mostly DDL like `CREATE INDEX CONCURRENTLY` and `ANALYZE` — runs through the in-cluster `bin/run-sql.js` helper in the application pod (which reuses the pod's PostgreSQL Entra identity), invoked through native `kubectl exec`:

```
kubectl exec deploy/zava-api -n zava-demo -- node bin/run-sql.js '<SQL>'
```

### Native kubectl (enabled)

This lab is configured so the agent uses **native `kubectl`** against the private cluster — the agent runs `kubectl get nodes` / `get pods` / `rollout undo` / `exec … run-sql.js` directly. The deploy now completes the private-cluster path automatically; two infra enablers plus a three-step in-session setup make it work:

**Infra — in `vnet.bicep` + `scripts/post-provision.ps1`:**
1. **DNS** — link the AKS-managed private-DNS zone `<guid>.privatelink.<region>.azmk8s.io` (in the cluster's `MC_…` resource group) to the **agent** VNet so the sandbox resolves the API-server FQDN. The zone name is dynamic and unknown until AKS creates it, so this cannot be a static Bicep resource. `scripts/post-provision.ps1` **Step 4b** discovers the node resource group, azmk8s.io private-DNS zone, and agent VNet, then idempotently creates the `agent-link` virtual-network link on every deploy:
   ```
   ZONE=$(az network private-dns zone list -g <MC_rg> --query "[?contains(name,'azmk8s')].name|[0]" -o tsv)
   az network private-dns link vnet create -g <MC_rg> -z $ZONE -n agent-link -v <agentVnetId> -e false
   ```
2. **Firewall** — `vnet.bicep` adds an allow rule (`agent-subnet 10.30.0.0/27 → aks-subnet 10.20.0.0/20 :443`) **and SNATs** all traffic (`snat.privateRanges = 255.255.255.255/32`). SNAT is essential: the API server's NSG only admits the `VirtualNetwork` tag and the agent spoke isn't *directly* peered to the platform spoke, so the agent's source IP is rewritten to the firewall's hub IP (which *is* in the tag) — that also makes the return path symmetric without touching the AKS subnet's routing.

**Agent in-session setup — encoded in the skill runbook:**
1. `az aks get-credentials -g <rg> -n <aks> --overwrite-existing`
2. `kubelogin convert-kubeconfig -l azurecli` — non-interactive managed-identity auth (the default device-code flow hangs in a sandbox).
3. The sandbox egress is a **TLS-inspecting forward proxy** that re-signs certs, so merge its CA (`/etc/ssl/certs/adc-egress-proxy-ca.crt`) into the kubeconfig's cluster `certificate-authority-data` so kubectl trusts the connection.

**Fallback — `az aks command invoke`:** still available, and the right choice for a *maximally* locked-down deployment where the firewall path to the API server is closed (remove the `allow-agent-to-aks-api` rule + SNAT from `vnet.bicep`). It's the Microsoft-recommended path for a private cluster with no API-server line of sight ([docs](https://learn.microsoft.com/en-us/azure/aks/access-private-cluster)), but has limits native kubectl avoids — one command at a time (no `-f`/interactive/port-forward), a **60-second ARM timeout**, and a **512-KB output cap** ([limitations](https://learn.microsoft.com/en-us/azure/aks/access-private-cluster#limitations-and-considerations)).

## Hub-and-Spoke & Talking to Network Devices

The network is modeled as **hub-and-spoke**, the shape most enterprises actually run (and the one Azure CAF / Azure Verified Modules' `hub-networking` pattern codifies):

- **Hub VNet** (`vnet-Zava-hub-*`, 10.10.0.0/22) holds the shared **Azure Firewall** (the agent's single egress point), a reserved **`GatewaySubnet`** where an **ExpressRoute/VPN gateway** to on-prem would attach, and the **Azure Monitor Private Link Scope (AMPLS)** private endpoint.
- **Platform spoke** (`vnet-Zava-platform-*`, 10.20.0.0/16) holds the workload — AKS + PostgreSQL.
- **Agent spoke** (`vnet-Zava-agent-*`, 10.30.0.0/24) holds the VNet-injected SRE Agent; its egress is force-tunneled to the hub firewall over VNet peering (UDR `0.0.0.0/0` → firewall).

This proves the agent operates identically when it's isolated in its own management spoke and reaches everything through a *shared* firewall — the real customer pattern. It's behavior-preserving because the agent reaches AKS via native `kubectl` over the private API-server path (with `az aks command invoke` as fallback) and PostgreSQL through an in-cluster pod — not raw DB sockets; moving it into a separate spoke changes only *which* firewall inspects its egress.

### The hub firewall doubles as a "network device" the agent can interrogate

All with the agent's own managed identity (no elevation):

| Path | How | What it answers |
|---|---|---|
| **Direct (config)** | `az network firewall [policy] show/list` — covered by the agent's Reader role | the device's *configuration*: rule collections, NAT rules, threat-intel mode |
| **Indirect (telemetry)** | KQL on `AZFWNetworkRule`, `AZFWApplicationRule`, `AZFWNatRule`, `AZFWDnsQuery` (firewall diagnostics → Log Analytics, resource-specific tables) | what the device *observed*: actual allow/deny events, top blocked FQDNs/IPs |

> **Network Watcher (optional, not wired in).** For deeper connectivity diagnostics you can add Azure Network Watcher — active `az network watcher` probes (connectivity check, next-hop, IP-flow verify, security-group view) plus NSG/VNet flow logs you can query with KQL. It's a standard Azure resource; to enable it, grant the agent a role on the regional `NetworkWatcherRG` (where the probes execute) and/or route flow logs to Log Analytics. It's left out by default to keep the footprint and cost minimal.

**Third-party devices (Palo Alto, Cisco, Fortinet, …)** don't accept Entra managed identity, and the agent's sandbox can't open raw TCP to a private IP. So the realistic patterns are: **(a) indirect** — the device ships syslog/CEF to Log Analytics (`Syslog` / `CommonSecurityLog`) via an Azure Monitor Agent forwarder, and the agent queries that; or **(b) direct via brokering** — front the device's HTTPS management API with an Entra-protected **API Management**/reverse proxy that validates the agent's MI token and injects the device key, *or* keep the device credential in **Key Vault** for the agent to read with its MI — then add the device FQDN to both the firewall application rules and the agent's egress allow-list. Absent that wiring, the agent stays on the telemetry path.

**Chat demonstration (no break needed).** Ask the agent: *"Inspect the hub Azure Firewall — show its egress allow-list and anything it denied for my subnet in the last hour."* It reads the policy over ARM (`az network firewall policy ...`) and queries the `AZFW*` tables, demonstrating the network-device interrogation directly. Because the firewall gates the agent's *own* egress, this is a read/diagnostic demonstration, not an autonomous break/fix.

### ExpressRoute / on-prem

A real ExpressRoute circuit can't be self-provisioned in a demo (it needs a connectivity provider to light up the circuit), so the topology **reserves** the `GatewaySubnet` and documents where the gateway attaches. To exercise hub-to-on-prem reachability cheaply, add a small peered "on-prem" VNet; for true gateway-transit semantics, deploy a VPN gateway in `GatewaySubnet` and flip `allowGatewayTransit` / `useRemoteGateways` on the peerings (cost + ~30-45 min deploy trade-off).

### Private Azure Monitor (AMPLS) — agent locked private by default

The Log Analytics workspace and Application Insights are scoped to an **Azure Monitor Private Link Scope** with a private endpoint in the hub (`infra/modules/monitor-private-link.bicep`). By default (`lockAgentToPrivateMonitor = true`) the **agent is locked to the private path**: its Monitor private-DNS zones are linked to the agent VNet and the public `AzureMonitor` service tag is dropped from the firewall L4 allow-list, so the agent reaches Log Analytics / Application Insights only over the AMPLS private endpoint (maximum restraint). Set `lockAgentToPrivateMonitor = false` to keep the public allow-listed Monitor path instead.

> **The agent stays fully functional under the lockdown.** With the lockdown on, the agent still queries Log Analytics / Application Insights and remediates incidents end-to-end (dispatch → investigate via Monitor + native kubectl → `kubectl rollout undo` → verify) over the private path. The agent's Monitor query connector is platform-brokered, so dropping the public `AzureMonitor` tag from the agent-VNet firewall doesn't gate it.

> **Workload (app) telemetry stays public by default.** `linkWorkloadVnetsToPrivateMonitor = false` on purpose: linking the *platform* spoke to the Monitor private-DNS zones forces the app's App Insights traffic onto the private endpoint, which only works if every endpoint in its connection string is served by the AMPLS zones. The regional App Insights **ingestion** host (`<region>-N.in.applicationinsights.azure.com`, from the component's connection string) is the classic gap: if it resolves into the private zone without a matching record it returns NXDOMAIN and the app silently stops shipping telemetry — a [documented private-link DNS pitfall](https://learn.microsoft.com/azure/azure-monitor/logs/private-link-security). This lab doesn't validate the workload's private path, so it's left public; the agent's lockdown is independent (it only *queries* Monitor, over its own spoke). Enable the toggle only after validating the workload's ingestion endpoints. For resource-level lockdown, switch the AMPLS access mode to `PrivateOnly` (riskier — can block operator public queries region-wide).

### Deploying in a hardened / enterprise tenant

This demo targets a permissive dev/sandbox subscription and works there as-is: it ships a Standard Azure Firewall with a public IP, a Basic ACR, AKS with local accounts enabled, and default public network access on the Log Analytics workspace / Application Insights (PostgreSQL is already VNet-integrated, with no public endpoint). A locked-down corporate landing zone with strict Azure Policy would likely require hardening those: `disableLocalAccounts` on AKS, a Premium ACR with a private endpoint, `publicNetworkAccess: 'Disabled'` on the workspace/App Insights, and a policy exemption for the firewall public IP. That hardened path isn't validated here.

## Platform Behaviors

For repo/IaC author gotchas (Sev4 quirk, NSG-vs-NetworkPolicy, container-image build path, Scenario 3 tuning, etc.), see [`AGENTS.md`](AGENTS.md) → Non-Obvious Things.

### Incident dispatch and merging

Azure Monitor itself does NOT link or merge incidents across different alert rules. Each alert rule fires independently, and the same rule re-firing just updates the existing alert's count (with `autoMitigate: true`, it flips to `Resolved` when the condition clears).

**Consequence for the two DB scenarios:** they share the single `postgres-unreachable` rule, so while the first alert is still `Fired`, a back-to-back second break just updates that instance instead of opening a new one — and the SRE Agent only dispatches on a *new* alert. To handle this, the `database-incidents` runbook has the agent **close the alert as its final step** once it verifies recovery (it holds the Contributor right for `Microsoft.AlertsManagement/alerts/changestate/action`), so the next DB break dispatches fresh; `autoMitigate` (~15-30 min) is the fallback if it doesn't. The other scenarios use distinct rules, so this only ever affected DB stop ↔ network partition.

**This sample disables agent-side merge on all four response plans** (`mergeEnabled: false`, `mergeWindowHours: 0`) — every incident opens its OWN investigation thread, with no deduplication. (For reference: when merge is *on*, the agent folds any matching alert arriving within `mergeWindowHours` into the most recent open thread for that plan instead of dispatching a new one. That deduplication can quietly hide real, distinct incidents, so this demo keeps it off.)

The four response plans / incident filters are `zava-database` (`postgres`), `zava-performance` (`query-slow`), `zava-application` (`http-5xx`), and `zava-unknown` (catch-all, Review mode). The `Zava-http-5xx-errors` alert also **no longer self-suppresses** on DB errors — a DB outage that returns 5xx will open both a `postgres-unreachable` thread and an app thread, so every real symptom surfaces its own investigation. The only deduplication left is the Azure Monitor shared-rule stateful behavior described in the box above, which affects only back-to-back DB stop ↔ partition.

A brand-new `azd env new` always gets fresh dispatch because the SRE Agent name includes a per-env suffix (e.g. `sre-agent-zava-awpo`), so a new env gets a new agent with an empty thread store.

### Microsoft Learn MCP (Streamable-HTTP) connector

The `microsoft-learn` connector is a remote **Streamable-HTTP** MCP server (`https://learn.microsoft.com/api/mcp`). It is configured to route **entirely through the hub Azure Firewall** — no platform bypass. Three non-obvious things:

0. **No platform escape hatch (`allowHttpMcpServerNetworkAccess: false`).** Left at its default-off on purpose. When `true`, the platform routes the MCP runtime endpoint as `Rewrite{RoutingMode=Platform}` — a broker that egresses *outside* the VNet, bypassing this firewall (it never even appears in the `AZFW*` logs). With it off, the MCP host falls under AzureVNet's default-Allow and egresses via the VNet → forced-tunnel → the firewall, so the runtime stream to `learn.microsoft.com` is gated by **our** allow-list like everything else — consistent with the lockdown thesis. (The only true pod-side bypass is the platform `ExperimentalSettings.HttpMcpInSandbox` flag, which defaults to the locked-down in-sandbox broker and isn't exposed here.)
1. **Its server bits come from GitHub raw.** The in-sandbox `mcp-broker` fetches the connector's server bits from `raw.githubusercontent.com` (the `microsoftdocs/mcp` repo) during the `tools/list` handshake. The firewall therefore allow-lists `raw.githubusercontent.com` (`allow-github-raw-mcp-bits` in `vnet.bicep`). Without it the connector provisions but shows *"no active connection"* with **zero tools**, even though `learn.microsoft.com` itself is reachable (a raw GET to `/api/mcp` returns `405` "use a streamable HTTP transport"). The connection idle-disconnects and re-handshakes, so the rule is needed durably, not just on first use. It's scoped to that single host — this is a **Standard** firewall, which matches FQDN/SNI only; pinning the exact repo path (`raw.githubusercontent.com/microsoftdocs/mcp/*`) would require Azure Firewall **Premium** + TLS inspection (`targetUrls`).
2. **MCP tools ship disabled (skill-gated).** MCP connector tools have `defaultMode: disabled` — they only surface when an incident skill that lists them is active. There is **no ARM/Bicep property** for per-tool enablement (the agent's `permissions` stays `null`), so `scripts/setup-sre-agent.ps1` (run post-provision) turns the three Learn tools on for the **global** roster via `POST /api/v2/agent/tools/configure` (`{overrides:[{name,enabled}]}`, merge semantics). Microsoft's own `srectl tool config set` CLI exists for exactly this gap.

## Prerequisites

- Azure subscription with Contributor access
- [Azure CLI](https://docs.microsoft.com/cli/azure/install-azure-cli) (2.60+)
- [Azure Developer CLI (azd)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) (1.9+)
- [PowerShell 7.4+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) — **required on Windows, WSL, Linux, or macOS**; `azd up` runs a pre-provision check and fast-fails if `pwsh` is missing

> **Note:** `kubectl` is **not** required on your local workstation. The AKS cluster is private; operator in-cluster operations in this repo go through `az aks command invoke` (wrapped by `Invoke-AksCommand` in `scripts/_aks-helpers.ps1`) because the operator workstation lacks the agent's VNet/DNS/proxy setup. The SRE Agent uses native `kubectl` primarily (private-DNS link + firewall rule + SNAT to the API server); `az aks command invoke` remains its fallback — see "How the Agent Operates Against a Private Backend" above.

> **Region default:** `azd up` will prompt for a location. The Bicep default is `swedencentral` (validated end-to-end there). To deploy elsewhere, pick another region at the prompt or run `azd env set AZURE_LOCATION <region>` before `azd up`. Any region with availability for AKS, PostgreSQL Flexible Server, and the SRE Agent resource provider works.

> **Cross-platform note:** All scripts in this repo target PowerShell 7.4+, which runs on Windows, macOS, and Linux. On macOS/Linux, invoke the demo scripts with `pwsh`, e.g. `pwsh ./.github/skills/running-demo/scripts/break-sql.ps1`. The `azd` hooks (`pre-provision`, `post-provision`) auto-select the correct shell per OS via `azure.yaml`.

## Cleanup

```bash
azd down --force --purge     # Deletes entire resource group
```

## Project Structure

```
zava-aks-postgres/
├── .github/
│   └── skills/                   # AI agent skills + co-located break/fix scripts
│       └── running-demo/scripts/ #   Scenario break/fix .ps1 (skill assets)
├── infra/                        # Bicep (AKS, PostgreSQL, SRE Agent, monitoring)
├── src/api/                      # Express.js API
├── src/storefront/               # Zava Athletic storefront UI
├── k8s/                          # Kubernetes manifests (${VAR} substitution)
├── scripts/                 # azd lifecycle hooks + shared helper
│   ├── _aks-helpers.ps1          #   Invoke-AksCommand wrapper (REST fallback)
│   ├── check-environment.ps1     #   azd preprovision hook
│   ├── post-provision.ps1        #   azd postprovision hook
│   └── setup-sre-agent.ps1       #   Knowledge file upload + verification
└── sre-config/                   # Knowledge base files (skills, response plans, and connectors are declared in infra/modules/sre-agent.bicep)
```

## License

MIT
