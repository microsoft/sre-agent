# Zava Learning — SRE Agent configuration (applied via Azure MCP)

The agent **resource** is deployed with Bicep (`infra/modules/sre-agent.bicep`).
Everything in this folder is the agent's **configuration**, applied to the running
agent with the **public Azure MCP SRE Agent tools** (`@azure/mcp@3.0.0-beta.16`+).
Because the Azure MCP server is publicly distributed, anyone running this lab can
apply the same configuration the same way.

## What gets applied

| Artifact | Purpose | Applied as |
|---|---|---|
| `connectors.json` | App Insights, Log Analytics, Azure Monitor, Microsoft Learn (MCP) data connectors | connector create |
| `skills/connectivity-triage/SKILL.md` | Edge/network incident runbook (App Gateway → NSG → ACA LB → APIs) | srectl skill apply |
| `skills/performance-investigation/SKILL.md` | App-tier incident runbook | srectl skill apply |
| `skills/rbac-audit/SKILL.md` | Read-only least-privilege audit | srectl skill apply |
| `skills/pr-delivery/SKILL.md` | Single owner of GitHub PR creation for an IaC or code fix; applies after live mitigation, and the PR it produces is referenced by `servicenow-change-management` | srectl skill apply |
| `skills/rca-analysis/SKILL.md` | RCA narrative — timeline, 5-Whys, contributing factors | srectl skill apply |
| `skills/evidence-before-after/SKILL.md` | Class-aware visual evidence — before/after path diagram for connectivity/config faults, time-series charts for performance/availability faults, plus a delta table | srectl skill apply |
| `skills/recommendations-next-steps/SKILL.md` | Prioritized preventive/detective/process actions with owners + dates | srectl skill apply |
| `skills/zava-reporting/SKILL.md` | Presents a branded **in-thread** executive summary (markdown + before/after visuals inline), then produces the downloadable deliverables (PPT deck / HTML email / Teams card), or whichever subset the agent requests — **deliverable-only, does not send** | srectl skill apply |
| `skills/pagerduty-incident-update/SKILL.md` | PagerDuty communication & closure — acknowledge, post a symptom-only summary note (with PR/CR links), and resolve once recovery is verified | srectl skill apply |
| `skills/servicenow-change-management/SKILL.md` | Single owner of the ServiceNow Change Request + attachment tools; applies after a PR is opened for the durable fix | srectl skill apply |
| `incident-filter.json` | Symptom-keyed response routing (`titleContains: Zava` → default agent, autonomous) | incident filter create |
| `../knowledge-base/zava-learning-architecture.md` | Architecture KB | knowledge upload |
| `../templates/zava-brand.md` | Zava corporate reporting/brand standard (colors, tone, layouts) — cited by the reporting skills via `SearchMemory` | knowledge upload (`zava-brand`) |
| `../templates/zava-report-template.md` | Canonical incident-report skeleton + deck/email/Teams formats | knowledge upload (`zava-report-template`) |
| `../tools/CreateServiceNowChangeRequest/` `../tools/UploadServiceNowAttachment/` | Custom ServiceNow PythonTools (referenced by the `servicenow-change-management` skill) | srectl tool apply |

## Placeholders (substituted at apply time from the lab RG / your inputs)

- `@@RG@@` — lab resource group name
- `@@REPO@@` — GitHub `owner/repo` for code-fix PRs (same repo that hosts the app + `infra/`)
- `@@APP_INSIGHTS_ID@@` / `@@APP_INSIGHTS_NAME@@` / `@@LOG_ANALYTICS_ID@@` / `@@LOG_ANALYTICS_NAME@@`
- `@@INCIDENT_PLATFORM@@` — `PagerDuty` (default) or `AzMonitor`

## Prerequisites

1. **Agent deployed** (`scripts/deploy-sre-agent.ps1`).
2. **Azure MCP server** with SRE tools wired into your client:
   ```
   npx -y @azure/mcp@latest server start
   ```
3. **RBAC for the caller**: `Reader` (control plane) + `SRE Agent Administrator`
   (`e79298df-d852-4c6d-84f9-5d13249d1e55`) on the agent.
4. **srectl** (the SRE Agent CLI) installed as a dotnet global tool — used to apply
   skills with their structured `tools` list (azmcp `skills create` cannot set tools).
   Override its path with `SRECTL_EXE` if it isn't on the default `~/.dotnet/tools` path.
5. **Secrets in env (never committed)** — see `.env.sample`:
   PagerDuty REST API token, ServiceNow URL/user/pass.

## Apply

`node scripts/configure-agent.mjs` substitutes the placeholders from the lab RG and your
`.env`, then creates the connectors, registers the **custom PythonTools via srectl**, applies
the **skills via srectl** (each `skills/<name>/SKILL.md` carries a `tools:` frontmatter list, so
tools show selected in the portal — tools are registered *before* the skills that reference them),
and sets the incident filter and knowledge against the target agent. ServiceNow is wired as
**change management only** — through the custom PythonTools, not as an incident connector
(incident management is PagerDuty's job).
The script temporarily points srectl's global config (`~/.sreagent/config.json`) at the
agent's data-plane endpoint and restores it afterwards. Re-running is idempotent.

## Design note — symptom-only

Skill/filter/alert names describe **symptoms**, never the cause. The agent diagnoses
NSG priority-inversion vs App Gateway probe vs app-tier from telemetry inside the
runbook — never from the alert/skill name.

## Skill catalog (the agent decides the order)

Each skill owns one concern and declares its scope in its `description`. **Skills do not call or
hand off to each other** — the custom agent selects and sequences whichever skills the incident
needs. The grouping below is the *typical* progression an investigation moves through, not a fixed
pipeline.

```
DIAGNOSE                DELIVER          CHANGE MGMT                 REPORT (deliverable-only)
connectivity-triage  ·                                          · rca-analysis
performance-invest.  ·   pr-delivery      servicenow-change-mgmt · evidence-before-after
rbac-audit (report)  ·   (GitHub PR)      (ServiceNow CR)        · recommendations-next-steps
                                                                 · zava-reporting (HTML report only)

INCIDENT COMMS & CLOSURE
pagerduty-incident-update  (acknowledge · summary note · resolve once recovery verified)
```

- **pr-delivery** is the single owner of GitHub PR creation (no native GitHub-PR tool exists;
  it uses `ExecutePythonCode` + `FindConnectedGitHubRepo`/`GetIaCForGitHub`). The agent invokes it
  after live mitigation instead of any incident skill opening PRs itself.
- The four **reporting** skills consume the `zava-brand` + `zava-report-template` memories and
  the built-in `Plot*` / `Query*` telemetry tools. `zava-reporting` first renders a branded
  **in-thread** markdown summary with the before/after visuals shown inline (the thread renders
  markdown + inline `Plot*` images, not HTML), then *produces* the downloadable deck/email/Teams
  artifacts — it does not send them. For this lab the `zava-incident-responder` runbook narrows the
  skill to **only the HTML report**.

