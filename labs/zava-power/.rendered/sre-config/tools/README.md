# SRE Agent Tools — Configuration Guide

This directory contains custom PythonTools used by the PowerGrid SRE
Agent. **Lab-specific values (subscription IDs, ADO org names, container
app names, etc.) are hardcoded** in each tool YAML — this matches the
existing convention in this repo. Anyone forking this lab into their
own environment must edit the values listed below before applying the
tools to their SRE Agent server.

The convention used in tool YAMLs is:

```python
# ===== LAB-SPECIFIC CONFIG — edit for your environment =====
SUBSCRIPTION_ID = "..."
# ===== SECRETS — set in SRE Agent portal, not committed =====
ADO_PAT = "<SET_VIA_SRE_AGENT_PORTAL>"
# ============================================================
```

* **LAB-SPECIFIC CONFIG** is committed to git. Edit before
  `srectl tool apply`.
* **SECRETS** are placeholder strings (`<SET_VIA_SRE_AGENT_PORTAL>`)
  that the SRE Agent portal substitutes at runtime. **Never commit
  real secret values.** Set them via the SRE Agent portal UI under the
  tool's secret manager.

---

## Configurable values by tool

### Custom tools added for deployment validation

| Tool | Key | Type | Example value |
|---|---|---|---|
| `GetActiveRevision` | `SUBSCRIPTION_ID` | config | `e964602f-6afc-4cc7-ba6b-3a796008e254` (Azure subscription with the Container Apps) |
| `ProbeServiceLatency` | — | (no config) | URL passed as a runtime parameter — fully portable |
| `BurstLoadTest` | — | (no config) | URL passed as a runtime parameter — fully portable |

> **Note on ADO operations.** The `release-orchestrator` agent and the
> `release-on-sre-fix` skill use the runtime's **built-in ADO MCP
> tools** (`GetPipelineRunHistory`, the run-pipeline tool, etc.) which
> are pre-authenticated via delegated OAuth — **no PAT and no extra MI
> setup required**. We deliberately do NOT ship custom PythonTools that
> wrap ADO REST, because:
> - PAT requires you to manage a secret.
> - DefaultAzureCredential gets a token for the SRE Agent's MI, but
>   that MI is not a member of the ADO org by default, so calls fail
>   with `TF401444`.
>
> If you fork this lab into an environment where built-in ADO MCP
> tools are unavailable, you have two options:
> 1. Add the SRE Agent's MI as a user in your ADO org
>    (`dev.azure.com/<org>/_settings/users`, give Basic access + the
>    Build/Release scopes you need), then write PythonTools that use
>    `DefaultAzureCredential` against ADO resource UUID
>    `499b84ac-1321-427f-aa17-267ca6975798`.
> 2. Or write PythonTools that use a PAT (committed as a placeholder,
>    set in the SRE Agent portal at runtime).

### Pre-existing tools that also need lab-specific edits

| Tool | Key | Type |
|---|---|---|
| `CreateServiceNowIncident` | `SERVICENOW_URL`, `SERVICENOW_USER` | config |
| `CreateServiceNowIncident` | `SERVICENOW_PASS` | **secret** |
| `UpdateServiceNowWorkNotes` | same | same |
| `LookupServiceNowIncident`  | same | same |
| `ResolveServiceNowIncident` | same | same |
| `UploadChartToServiceNow`   | `SUBSCRIPTION`, `RESOURCE_GROUP`, plus SNOW values | config + secret |

### Skill prose with lab-specific identifiers

The following skills contain hardcoded service URLs / container app
names that lab forks must update:

| Skill | Where |
|---|---|
| `deployment-validation` | "Service inventory" table (URLs and ACA names) |
| `outage-api-diagnosis`, `meter-api-diagnosis`, `grid-status-diagnosis`, `notification-svc-diagnosis` | KQL `where ContainerAppName_s ==` and `az containerapp` commands |
| `servicenow-incident-mgmt` | example incident bodies |

---

## Required SRE Agent portal configuration

Beyond the per-tool secrets above, you also need:

1. **Service principal authentication** — DefaultAzureCredential is
   used by `GetActiveRevision`. The SRE Agent's managed identity (or
   the service principal it runs as) needs `Microsoft.App/containerApps/revisions/read`
   on the resource group containing the Container Apps.
2. **Release-trigger wiring** —
   - `deployment-validator` agent: trigger on `ReleaseSucceeded` for
     your release pipeline.
   - `release-orchestrator` agent: trigger on `BuildSucceeded` for
     your build pipeline.
3. **Pipeline IDs** — the agent prompts reference numeric pipeline IDs
   (PowerGrid-Build = 4, PowerGrid-Release = 5 in this lab). Update the
   prose in `sre-config/agents/deployment-validator.yaml` and
   `sre-config/agents/release-orchestrator.yaml` if your IDs differ.
4. **Teams channel ID** — the success-path Teams notifications use the
   channel ID injected by the release-trigger event payload, so no
   per-tool config required.

---

## Apply workflow for a fresh fork

```powershell
cd sre-config
# 1. Edit each tool YAML's LAB-SPECIFIC CONFIG block per the table above.
# 2. Validate then apply each tool:
foreach ($t in 'ProbeServiceLatency','BurstLoadTest','GetActiveRevision') {
  srectl tool validate --name $t
  srectl tool apply    --name $t
}
# 3. Apply skills (skills/<name>/SKILL.md):
cd ..
foreach ($s in 'deployment-validation','perf-regression-diagnosis','crash-regression-diagnosis','config-regression-diagnosis','release-on-sre-fix') {
  srectl skill apply --name $s
}
# 4. Apply agents:
cd sre-config
foreach ($a in 'deployment-validator','release-orchestrator') {
  srectl agent apply --name $a
}
# 5. In the SRE Agent portal: set secrets for each tool listed above
#    and wire the release/build triggers to the two agents.
```
