# Zava Learning — Azure SRE Agent lab

A templatized, end-to-end lab that simulates a **online learning platform**
("Zava Learning") and lets the **Azure SRE Agent** autonomously diagnose and remediate planted
faults — across the **network/edge** and the **application** tiers — while integrating with
**PagerDuty** (incident platform), **ServiceNow** (change management), and **GitHub** (code-fix PRs).

> The platform deploys healthy. Faults are injected on demand by the chaos scripts / demo simulator,
> so the SRE Agent has a real, observable problem to investigate.

---

## What gets deployed

| Resource | Purpose |
|---|---|
| VNet `vnet-zava-*` (10.20.0.0/16) | `appgw-subnet` (10.20.1.0/24) + `aca-infra-subnet` (10.20.2.0/23) |
| `nsg-aca-*` | NSG on the apps subnet — **carries the connectivity fault** when injected |
| Container Apps env `cae-zava-*` (internal) | Hosts the three services, VNet-integrated |
| `learner-portal` | Student web portal (App Gateway backend) |
| `course-api` | Course catalog API (internal) |
| `assessment-api` | Quiz/assessment API (internal) — quiz launch path |
| App Gateway `agw-zava-*` (+ public IP) | Public entry point; HTTP :80 → portal backend |
| ACR `acrzava*` | Service images |
| Managed identity `id-zava-*` | ACR pull + (reused by the SRE Agent) |
| Log Analytics + App Insights | Telemetry the agent reasons over |
| Action group + symptom-only alerts | `Zava-quiz-launch-failing`, `Zava-portal-5xx-elevated`; webhook → PagerDuty |

**Not** deployed by the main template: the **SRE Agent** itself — provisioned separately (see below).

Architecture detail: [`sre-config/knowledge-base/zava-learning-architecture.md`](sre-config/knowledge-base/zava-learning-architecture.md).

---

## Prerequisites

```powershell
pwsh ./scripts/check-environment.ps1
```

Azure CLI, Bicep, azd, PowerShell 7+, Python 3, Docker (for image builds), and `az login`.

---

## Deploy

### Option A — azd (recommended)

```powershell
azd up    # prompts for environment name, region, subscription; builds images + provisions
```

### Option B — az CLI

```powershell
# 1. Provision everything except the SRE Agent
az deployment sub create `
  --location eastus2 `
  --template-file infra/main.bicep `
  --parameters environmentName=demo location=eastus2 `
               dbAdminPassword="<strong password>" `
               dbPoolPassword="<strong password>" `
               vmAdminPassword="<strong password>" `
               pagerDutyWebhookUrl="<optional PD integration URL>"

# 2. Build/push images, point apps at them, write the simulator config
pwsh ./scripts/post-provision.ps1 -ResourceGroup rg-zava-learning-demo
```

The public endpoint is the App Gateway public-IP FQDN (also written to `simulator/config.json`).

---

## Provision the SRE Agent (separate step)

The lab leaves the SRE Agent to you so you control its identity/cost. Once the RG exists, deploy the
**agent resource + RBAC** — an empty shell with no behavior yet:

```powershell
pwsh ./scripts/deploy-sre-agent.ps1 `
  -ResourceGroup rg-zava-learning-demo `
  -IncidentPlatform PagerDuty `
  -GitHubRepository "<owner>/<repo>"
```

This deploys [`infra/modules/sre-agent.bicep`](infra/modules/sre-agent.bicep) — **only** the
`Microsoft.App/agents` resource and its role assignments. All agent *behavior* is applied in the next
step.

---

## Configure the SRE Agent

Bicep deploys the shell; this step gives the agent everything it needs to act:

- **4 custom agents** — `zava-incident-responder` (reactive incidents) + `zava-nsg-auditor`,
  `zava-rbac-auditor`, `zava-cost-analyst` (weekly read-only governance audits)
- **17 skills**, each with its structured `tools:` — triage, RCA, evidence, recommendations,
  PR delivery, ServiceNow change management, reporting, the three audits, and redaction
- **2 custom PythonTools** — `CreateServiceNowChangeRequest`, `UploadServiceNowAttachment`
- **Connectors** — App Insights, Log Analytics, Azure Monitor, Microsoft Learn (MCP), PagerDuty
- **Incident filter** `zava-learning-response` — symptom-keyed, autonomous, routed to the incident agent
- **Knowledge base** — architecture + the brand / report / audit / redaction standards
- **3 weekly audit scheduled tasks** — NSG, RBAC, cost

Every artifact is checked in under [`sre-config/`](sre-config/). Placeholders (`@@RG@@`, `@@REPO@@`,
`@@SERVICENOW_*@@`) are your values, substituted at apply time.

### Option A — automated (`scripts/configure-agent.mjs`) — requires `srectl`

```powershell
$env:AZURE_SUBSCRIPTION_ID = "<your-sub>"
node scripts/configure-agent.mjs    # idempotent; re-runnable
```

One script applies **everything** above. It drives two CLIs:

- **`azmcp`** — the public Azure MCP SRE tools (`npm i -g @azure/mcp@latest`) — applies connectors + knowledge.
- **`srectl`** — the full SRE Agent CLI — applies the skills (with their structured tools), the 4
  custom agents, and the PythonTools, which `azmcp` cannot express.

> ⚠️ **`srectl` is not publicly released yet.** Until it ships, this script cannot apply the
> skills / agents / tools — so **use the manual portal walkthrough below (Option B)**. Every piece of
> this lab is fully configurable in the Azure portal. Once `srectl` is public, `configure-agent.mjs`
> becomes a one-command setup.

### Option B — manual, via the Azure portal (use this today)

All of it is portal-configurable. In the SRE Agent blade for your agent, working from `sre-config/`:

1. **Connectors** → add App Insights, Log Analytics, Azure Monitor, the Microsoft Learn MCP endpoint
   (`https://learn.microsoft.com/api/mcp`), and PagerDuty.
2. **Knowledge** → add each file under `sre-config/knowledge-base/` and `sre-config/templates/`
   (architecture KB + the `zava-brand` / `zava-report-template` / `zava-audit-report` / `zava-redaction`
   standards) as a knowledge entry.
3. **Tools** → create the two PythonTools from `sre-config/tools/*/` (paste the function code; replace
   the `@@SERVICENOW_*@@` placeholders with your ServiceNow URL / user / pass).
4. **Skills** → create one skill per `sre-config/agent-config/skills/<name>/SKILL.md` — paste the body
   and attach the tools named in its `tools:` frontmatter.
5. **Custom agents** → create the 4 agents from `sre-config/agent-config/agents/<name>/<name>.yaml`,
   scoping each to its `allowedSkills` and setting autonomous mode.
6. **Incident filter / response plan** → add `zava-learning-response` (title contains `Zava`,
   autonomous, routed to `zava-incident-responder`) — spec in `sre-config/agent-config/incident-filter.json`.
7. **Scheduled tasks** → create the 3 weekly audits from `sre-config/scheduled-tasks/*.yaml` (cron,
   agent, prompt).

Substitute your own values for every `@@…@@` placeholder as you paste.

---

## Integrations

- **PagerDuty (incident platform).** Create a PagerDuty service with the **"Microsoft Azure"**
  integration, copy its Integration URL, and pass it as `pagerDutyWebhookUrl`. Azure Monitor raises
  the PagerDuty incident; the agent acknowledges/annotates/resolves it.
- **ServiceNow (change management).** Two custom tools under `sre-config/tools/`
  (`CreateServiceNowChangeRequest`, `UploadServiceNowAttachment`) — credentials read from env
  (`SERVICENOW_URL/USER/PASS`), **never committed**.
- **GitHub (code fix).** The **`pr-delivery`** skill opens an IaC or application fix PR against the
  repo you pass to `deploy-sre-agent.ps1` (via `ExecutePythonCode` + the GitHub API — the runtime
  has no native GitHub-PR tool). The agent invokes it after live mitigation; the
  `servicenow-change-management` skill then records the Change Request referencing the PR.
- **Reporting (deliverables).** After remediation, the `rca-analysis`, `evidence-before-after`,
  `recommendations-next-steps`, and `zava-reporting` skills produce a branded RCA report, before/after
  visuals, and an executive deck / email / Teams card from the `zava-brand` + `zava-report-template`
  standards (deliverable-only — produced, not auto-sent).

---

## Run the demo

```powershell
python ./simulator/demo.py            # interactive menu
python ./simulator/demo.py --scenario nsg
python ./simulator/demo.py --status   # one-shot health probe
python ./simulator/demo.py --scenario nsg --auto-fix   # dry run without a live agent
```

The simulator narrates the business context, injects the fault, then live-monitors the platform's
health while polling for the **Azure Monitor alert**, the **PagerDuty incident**, and the **SRE Agent**
response — and reports recovery. PagerDuty / agent polling turns on when `agent_name` and
`pagerduty.api_token` are available: set them in `simulator/config.json`, or leave them blank and
the simulator falls back to env vars — `agent_name`←`ZAVA_AGENT`, and the PagerDuty token/service id
are auto-loaded from the gitignored `sre-config/.env` (`PAGERDUTY_API_TOKEN` / `PAGERDUTY_SERVICE_ID`),
so the secret can stay out of `config.json`.

### Scenarios

| Key | Symptom (student-facing) | Injected fault | Built-in skills exercised |
|---|---|---|---|
| `nsg` | Quizzes won't launch | NSG priority-inversion DENY blocks App Gateway → apps | network_connectivity_troubleshoot, network_topology_mapper |
| `appgw` | Portal returns 502s | App Gateway health probe pointed at a bad path | application_gateway_troubleshoot |
| `app` | Quizzes won't launch | `assessment-api` scaled to zero replicas | app_insights_query, log_analytics_query |
| `perf` | Quizzes are slow | Bad release ships a slow quiz-service image (`:v1.1`) | app_insights_query, log_analytics_query |
| `query` | Quizzes are slow | question_bank index corruption → planner full-scans 500k rows | log_analytics_query |
| `pool` | Quizzes fail under load | DB connection-pool exhaustion (clamped role) | log_analytics_query |
| `secret` | Quizzes fail completely | Key Vault DB credential rotated to an invalid value | log_analytics_query |
| `disk` | Nightly grade exports fail | Reporting-worker VM data disk fills up (no space left) | log_analytics_query |

The chaos scripts live in [`chaos/`](chaos/) (`break-*.ps1` / `fix-*.ps1`).

---

## Templatization

- `azd up` prompts for environment / region / subscription; all resource names derive from a token.
- Every secret (PagerDuty, ServiceNow) is a parameter or environment variable — **nothing is committed**.
- Symptom-only alert naming is enforced (see `AGENTS.md`): alerts never reveal the cause.

---

## Repo layout

```
azure.yaml                      azd service + infra config
infra/
  main.bicep                    subscription-scoped entry (creates RG, all non-agent resources)
  modules/                      monitoring, identity, network, aca, dns, appgw, alerts, sre-agent
src/                            learner-portal, course-api, assessment-api (Node/Express + Dockerfiles)
sre-config/
  agent-config/
    skills/                     17 skills (SKILL.md + structured tools:)
    agents/                     4 custom agents (incident responder + NSG/RBAC/cost auditors)
    connectors.json             data connectors (App Insights, Log Analytics, Monitor, Learn MCP)
    incident-filter.json        symptom-keyed response plan (zava-learning-response)
  tools/                        ServiceNow change-request + attachment PythonTools
  scheduled-tasks/              3 weekly audit tasks (NSG / RBAC / cost)
  knowledge-base/               architecture KB for the agent
  templates/                    brand + report + audit + redaction standards
chaos/                          break-*/fix-* fault scripts
scripts/                        check-environment, post-provision, deploy-sre-agent, configure-agent.mjs
simulator/                      story-driven demo simulator (demo.py)
docs/                           architecture deck (build_architecture_deck.py)
```
