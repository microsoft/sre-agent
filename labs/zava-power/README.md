# PowerGrid ZeroOps — SRE Agent lab

A full **azd up** lab for Azure SRE Agent on Container Apps, modeled after the
**Zava Power Limited** fictional utility. Customers see the entire incident
lifecycle: alert → SNOW incident → autonomous diagnosis → remediation → audit
trail → resolution.

## Stack

- **App**: 5 microservices — `outage-api` (Python 3.11 / Flask 3.1 / Gunicorn), `meter-api` (.NET 8 / ASP.NET), `grid-status-api` (Node.js 20 / Express 4.21), `notification-svc` (Go 1.22 / native HTTP), `portal-web` (React 18 / Vite / nginx). All instrumented with Application Insights SDK.
- **Compute**: Azure Container Apps (default); optional AKS via the `computePlatform` Bicep param; optional Azure Arc-enabled Windows VM for hybrid scenarios
- **Data**: None (microservices are stateless; ServiceNow PDI is the system of record for tickets)
- **Observability**: Log Analytics + Application Insights + Azure Managed Grafana + Azure Monitor alert rules
- **SRE Agent**: `sre-zavapower-ops` — 8 subagents (`incident-handler`, `deployment-validator`, `vm-ops-agent`, `utility-ops-agent`, `web-app-troubleshooter`, `pod-incident-remediator`, `release-orchestrator`, `pipeline-failure-investigator`), 15 skills (per-service diagnosis + crash/config/perf classes + ops procedures), incident filter `auto-investigate-azmon`, daily `pod-fleet-audit-daily` scheduled task. ServiceNow MCP connector for ticketing.
- **Simulator**: Python rich-CLI demo (`simulator/demo.py`) with 7 break/fix scenarios; failure payloads in `bugs/` injected by the build pipeline via `failure_scenario` parameter
- **CI/CD**: `azd up` for the lab; Azure DevOps pipelines (`pipelines/build.yml`, `pipelines/release.yml`) for the deployment-validator demo path

## What it's about

The Zava Power lab is for PMs, SREs, and customers who want to see the **Azure SRE Agent run production-ops across a realistic, multi-language microservice fleet** with full ServiceNow integration. Zava Power Limited is a fictional electric utility; the platform models its operational stack — outage tracking, meter ingestion, grid status, customer notifications, and a customer portal — so the agent has to reason across services written in 4 different languages, plus an optional Arc-enabled Windows VM for hybrid scenarios. The lab teaches break/fix patterns for app crashes on deploy, perf regressions that block the event loop, container config errors, OOMKill/CrashLoopBackOff fleet audits, VM disk pressure, ADO pipeline failures, and release orchestration / canary cutovers.

Demo flow: `azd up` provisions infra (~8 min), builds and pushes the 5 service images via ACR Tasks (~10 min), applies the SRE Agent config via `srectl`, and launches `simulator/demo.py`. From the simulator, pick a scenario → it injects the fault → an Azure Monitor alert fires → the SRE Agent opens a ServiceNow incident, investigates via Log Analytics + App Insights, remediates (rollback / config fix / scale-out / VM cleanup), and resolves the SNOW ticket with a full audit trail. Total time on a fresh subscription: ~20–25 min, no other commands needed.

## What you get

- 5 microservices on Azure Container Apps (Python, .NET, Node, Go, React)
- **SRE Agent instance:** `sre-zavapower-ops` — investigates infra/app alerts, opens & closes ServiceNow incidents
- ServiceNow PDI integration via MCP connector
- Azure Monitor + App Insights + Log Analytics + Managed Grafana
- Optional Arc-enabled Windows VM for hybrid scenarios
- 7 break/fix scenarios driven by `simulator/demo.py`

## Quick start (one command)

```bash
azd auth login         # one-time
az login               # one-time

azd up                 # ⇽ THIS IS THE ONLY COMMAND
```

`azd up` will:

1. **Prompt** for the few values it can't infer (Azure subscription, region,
   ServiceNow PDI hostname + admin credentials).
2. **Provision** Azure resources via bicep (~8 min).
3. **Build & push** the 5 service container images via ACR Tasks (~10 min).
4. **Apply** SRE Agent config (subagents, skills, hooks, scheduled tasks).
5. **Launch** the simulator's interactive scenario picker — you're in the demo.

Total time: **~20-25 min** on a fresh subscription. No other commands needed.

> Pre-reqs (preprovision hook checks for these): `az`, `azd`, `pwsh` (7+),
> `python` (3.11+), `docker`, `srectl`. Install any missing ones first.

To re-run the simulator later without re-deploying:

```bash
python simulator/demo.py
```

To tear everything down:

```bash
azd down --purge --force
```

## Scenarios

| # | Name | What breaks | What the agent does |
|---|---|---|---|
| 1 | VM disk pressure | Arc VM disk > 90% | Identifies + cleans temp dirs, updates SNOW |
| 2 | API perf regression | grid-status-api blocks event loop | Detects high-latency, rolls back revision |
| 3 | Pod incident audit | Pods OOMKill / CrashLoopBackOff | Aggregates 24h pod failures into SNOW deck |
| 4 | App crash on deploy | outage-api `.upper()` on None | Auto-rolls back, opens fix PR |
| 5 | Config error | Wrong port in environment | Detects in App Insights, fixes config |
| 6 | Pipeline failure | ADO build red | pipeline-failure-investigator analyzes logs |
| 7 | Release orchestration | Manual rollout | release-orchestrator drives canary cutover |

See `docs/scenarios/` for per-scenario deep dives.

## Architecture

See `docs/architecture.md`.

## RBAC modes

The lab assigns the SRE Agent's managed identity one of three permission tiers, automatically chosen at deploy time. The probe runs in `scripts/check-environment.ps1` (preprovision hook) and prompts you when the preferred tier isn't available.

| Tier | Operator role | Agent capabilities | When you get this |
|---|---|---|---|
| **T1 — custom (preferred)** | `PowerGrid SRE Agent Operator` (11 specific actions on the RG) | Full autonomous remediation: rollback CA revisions, restart VMs, run hybrid-compute commands | Default. Probe creates the role from `infra/roles/powergrid-sre-agent-operator.json` (idempotent) |
| **T2 — built-in Contributor** | `Contributor` scoped to the RG | Same as T1, but broader perms | T1 unavailable (e.g., tenant custom-role limit hit, or caller lacks `roleDefinitions/write`). Probe prompts; you choose `[1] Contributor` |
| **T3 — read-only** | _(none)_ | Detect + diagnose only. Every remediation request goes through the agent's approval flow to a human admin | T1 unavailable and you choose `[2] Read-only`, **or** `azd up --no-prompt` (defaults to T3) |

`Reader`, `Monitoring Reader`, and `Log Analytics Reader` are granted in **all 3 tiers** so the agent can always observe the workload.

The agent's `actionConfiguration.mode = Review` means every action requires human approval regardless of tier — in T3 the admin completes the action manually with their own perms.

### Override the probe

```bash
azd env set RBAC_TIER custom        # or contributor / readonly
azd provision
```

When `RBAC_TIER` is explicitly set, the probe is skipped. Useful for CI or when re-deploying.

### Upgrade later

If T2 or T3 was used and you later want T1 (e.g., admin freed up tenant role-quota):

```bash
azd env set RBAC_TIER custom
azd provision
```

### Files

- `infra/roles/powergrid-sre-agent-operator.json` — role definition (uses `<SUBSCRIPTION_ID>` + `<RESOURCE_GROUP>` placeholders, substituted at probe time)
- `infra/modules/sre-agent.bicep` — conditional role assignments based on `rbacTier` param
- `scripts/check-environment.ps1` — the T1→T2→T3 probe + prompt
- `docs/SRE-AGENT-MI-ACCESS.md` — full action→command mapping per tier

## Cleanup

```bash
azd down --purge
```

## Related

This lab's `sre-config/` is the source for two recipes in
`sreagent-templates/recipes/`:

- `azmon-aca-servicenow-powergrid-ops`

Use those recipes if you want JUST the agent (without the full lab infra).

## Source

Originally developed at [github.com/sandeepaziz/ppl-zeroops-lab](https://github.com/sandeepaziz/ppl-zeroops-lab)
and contributed upstream. See [AGENTS.md](./AGENTS.md) for non-obvious gotchas
when editing this lab's IaC.
