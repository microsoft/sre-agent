# Azure SRE Agent — Labs

A collection of self-contained, end-to-end **Azure SRE Agent** demo labs. Each lab is a single `azd up` package — Bicep infra + sample app + agent config + break/fix scenarios — built to demo investigation, diagnosis, and autonomous remediation in 20–40 minutes.

> **Multiple labs?** See [`LAUNCHER.md`](LAUNCHER.md) — `./lab.sh` picks any combination of labs to deploy.
>
> **Authoring a new lab?** See [`AGENTS.md`](AGENTS.md) and [`_platform/`](_platform/).
>
> **Want just the agent config (no infra)?** See [Recipes](#recipes) below.

---

## Labs at a glance

| # | Lab | What it demos | Stack | Compute | Difficulty |
|---|---|---|---|---|---|
| 1 | [`zava-eats`](zava-eats/) | **Starter lab** — break a Node.js food-ordering app, watch the agent diagnose HTTP 5xx and remediate. GitHub OAuth + 3 subagents. | Node.js / Express (Grubify) | Azure Container Apps | ★ |
| 2 | [`zava-cafe`](zava-cafe/) | Azure SQL DTU spikes, missing indexes, blocking chains, post-deploy regression validation with rollback. Includes safety hooks (write-guard + change-risk assessor). | .NET 8 / ASP.NET Core (specialty coffee e-commerce) | Azure App Service + Azure SQL DB | ★★ |
| 3 | [`zava-itsupport`](zava-itsupport/) | IT helpdesk laptop-replacement workflow — ServiceNow ticket → warranty lookup → Browser Operator drives procurement portal. | Node.js 20 portal + Python 3.11 / FastAPI warranty API | Azure Container Apps + ServiceNow MCP | ★★ |
| 4 | [`zava-power`](zava-power/) | **Microservice ops at scale** — utility platform with 5 services, 8 subagents, 15 skills, full incident lifecycle (detect → investigate → remediate → resolve in ServiceNow). | Python/Flask + .NET 8 + Node.js 20 + Go 1.22 + React (5 microservices) | Azure Container Apps (+ optional Arc-VM, AKS) | ★★★ |
| 5 | [`zava-athletic`](zava-athletic/) | **AKS + private Postgres** scenarios: PG stop, NetworkPolicy egress block, missing-index slow-query. Anthropic-backed agent with 8 AzMon alerts. | Node.js / Express e-commerce | AKS (private cluster) + PostgreSQL Flexible Server | ★★★ |
| 6 | [`zava-infra`](zava-infra/) | **Infrastructure governance** umbrella — see 3 sub-scenarios below. | Mixed | Mixed (ACA, App Service, VM, Cosmos DB) | ★★ |

### `zava-infra` sub-scenarios

| Sub-scenario | What it demos |
|---|---|
| [`zava-infra/scenarios/perf-drift`](zava-infra/scenarios/perf-drift/) | VM CPU/memory pressure + Cosmos DB RU drift; Azure Monitor alerts → agent investigates SAP-style workload on Windows VMs. |
| [`zava-infra/scenarios/compliance`](zava-infra/scenarios/compliance/) | Container App revision compliance — Activity Log alert when an out-of-policy image is deployed; agent rolls back via approval hook. |
| [`zava-infra/scenarios/tf-drift`](zava-infra/scenarios/tf-drift/) | Terraform Cloud drift detection — webhook → agent diagnoses drift, opens PR with `terraform plan` summary. (Manual deploy.) |

---

## Recipes

Portable, lab-agnostic SRE Agent config bundles — agent + subagents + skills + hooks + tools — that you can apply to **your own** workload (no infra, no app code).

| Recipe | Source lab | What you get |
|---|---|---|
| [`recipes/azmon-aca-servicenow-zavacafe-ops`](recipes/azmon-aca-servicenow-zavacafe-ops/) | [`zava-cafe`](zava-cafe/) | SQL ops + deployment validation: 3 subagents, 4 skills, 2 hooks. App Insights, AzMon, ServiceNow, Azure SQL MCP, ADO. |
| [`recipes/azmon-aca-servicenow-zavapower-ops`](recipes/azmon-aca-servicenow-zavapower-ops/) | [`zava-power`](zava-power/) | Microservice ops: 8 subagents, 15 skills. AzMon, ServiceNow, optional Datadog & Dynatrace MCP. |
| [`recipes/azmon-aca-servicenow-zavaitsupport`](recipes/azmon-aca-servicenow-zavaitsupport/) | [`zava-itsupport`](zava-itsupport/) | IT helpdesk laptop replacement: 1 subagent, ServiceNow Incident Platform, `CheckWarranty` + `LookupServiceNowIncident` tools, Browser Operator. |

See [`recipes/README.md`](recipes/README.md) for the recipe authoring + upstream contribution flow.

---

## Pick a lab

**By experience level:**

- **First time?** → [`zava-eats`](zava-eats/) (★, ~40 min, no GitHub required)
- **Want SQL incidents?** → [`zava-cafe`](zava-cafe/) or [`zava-athletic`](zava-athletic/)
- **Want microservices?** → [`zava-power`](zava-power/)
- **Want IT helpdesk / ServiceNow flows?** → [`zava-itsupport`](zava-itsupport/)
- **Want AKS + private network?** → [`zava-athletic`](zava-athletic/)
- **Want infra governance / drift / compliance?** → [`zava-infra`](zava-infra/)

**By compute platform:**

| Platform | Labs |
|---|---|
| Azure Container Apps | `zava-eats`, `zava-itsupport`, `zava-power`, `zava-infra/compliance` |
| Azure App Service | `zava-cafe` |
| AKS | `zava-athletic` |
| Azure VMs (Windows) | `zava-infra/perf-drift` |

**By data tier:**

| Data | Labs |
|---|---|
| Azure SQL DB | `zava-cafe` |
| PostgreSQL Flexible Server | `zava-athletic` |
| Cosmos DB | `zava-infra/perf-drift` |
| In-memory only | `zava-eats`, `zava-itsupport`, `zava-power` |

---

## Prerequisites (shared across all labs)

| Tool | macOS | Windows |
|---|---|---|
| [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.60+ | `brew install azure-cli` | `winget install Microsoft.AzureCLI` |
| [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) 1.9+ | `brew install azd` | `winget install Microsoft.Azd` |
| [Git](https://git-scm.com/) 2.x | `brew install git` | `winget install Git.Git` (includes Git Bash) |
| [Python](https://python.org) 3.10+ | `brew install python3` | `winget install Python.Python.3.12` |

Plus per-lab tools listed in each lab's README (e.g., `kubectl` not required for `zava-athletic`; `pwsh` for `zava-cafe`).

**Azure requirements (every lab):**
- Active Azure subscription
- **Owner** role on the subscription (needed for RBAC role assignments)
- `az provider register -n Microsoft.App --wait`
- SRE Agent regions: `eastus2`, `swedencentral`, `australiaeast`

Run [`scripts/prereqs.sh`](scripts/prereqs.sh) to verify your environment.

---

## Quick start (any lab)

```bash
git clone https://github.com/dm-chelupati/sre-agent-lab.git
cd sre-agent-lab
git submodule update --init --recursive

az login && azd auth login

cd labs/<lab-name>          # e.g. labs/zava-eats
azd env new <env-name>
azd up                       # pick subscription + region (eastus2 recommended)
```

Each lab's README has the exact post-deploy steps — open the agent at [sre.azure.com](https://sre.azure.com), then run the lab's break script.

---

## Cleanup (any lab)

```bash
cd labs/<lab-name>
azd down --purge
```

---

## Links

- [Azure SRE Agent docs](https://sre.azure.com/docs)
- [Getting started](https://sre.azure.com/docs/get-started/create-and-setup)
- [Connectors](https://sre.azure.com/docs/concepts/connectors)
- [Custom subagents](https://sre.azure.com/docs/concepts/subagents)
- [Incident response](https://sre.azure.com/docs/capabilities/incident-response)
- [Multi-lab launcher (`LAUNCHER.md`)](LAUNCHER.md)
- [Recipes (portable agent configs)](recipes/)
- [Lab authoring guide (`AGENTS.md`)](AGENTS.md)

## License

MIT
