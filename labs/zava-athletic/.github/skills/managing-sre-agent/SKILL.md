---
name: managing-sre-agent
description: "Manage Azure SRE Agent configuration for this demo: connectors, skills, response plans, and the knowledge base. Use when asked to create, list, update, or delete SRE Agent resources."
---

# SRE Agent Administration

For **this demo**, agent configuration is declared in Bicep
(`infra/modules/sre-agent.bicep`). The following all flow through
`Microsoft.App/agents/*` ARM resources:

- **Agent settings** — autonomous mode, High access level, Azure Monitor incident binding
- **Connectors** — `app-insights`, `log-analytics`, `azure-monitor` (MonitorClient), `microsoft-learn` (MCP)
- **Custom skills** — `db-incident-investigation`, `proactive-health-check`
- **Response plans / incident filters** — `zava-db-response`, `zava-app-response`
  (route 8 alerts via `titleContains` patterns)
- **RBAC** — system-assigned managed identity granted Reader, Monitoring Reader,
  Contributor, and AKS RBAC Cluster Admin on the resource group

To change any of these, **edit the Bicep and run `azd provision`**. There is no
data-plane CLI tool for them in this repo.

## Knowledge base (the one data-plane piece)

ARM does not yet surface SRE Agent knowledge files, so they're uploaded by
`scripts/setup-sre-agent.ps1`:

```powershell
.\scripts\setup-sre-agent.ps1
```

The script reads every `*.md` under `sre-config/knowledge-base/`, substitutes
`@@RG@@` -> the actual resource group, computes a SHA256, and uploads only files
whose content has changed since the last run (cache in
`sre-config/knowledge-base/.upload-hashes.json`). To add new agent knowledge:

1. Drop a new `*.md` file into `sre-config/knowledge-base/`
2. Use `@@RG@@` placeholder anywhere you need the resource group name
3. Re-run `.\scripts\setup-sre-agent.ps1`

To remove a knowledge file: delete the local `.md`, then delete the corresponding
`<name>.md` from the agent's Builder UI > Knowledge sources view (the
script does not delete remote files that are no longer present locally).

## When helping users

1. **"Add a skill / response plan / connector"** — edit `infra/modules/sre-agent.bicep`
   and run `azd provision`. Show the user the relevant resource block as a template.
2. **"Add a knowledge file"** — drop the markdown under `sre-config/knowledge-base/`
   and run `setup-sre-agent.ps1`.
3. **"Verify the agent is configured"** — run `setup-sre-agent.ps1`; its Step 3
   output reports `[OK]` or `[MISSING]` for every Bicep-deployed asset.
4. **Activity-log alerts gotcha** — they fire as Sev4 regardless of the configured
   severity, so response plan filters must match all severities (Bicep already does).
5. **Runbook content is intentionally non-prescriptive** — the `dbIncidentSkill` in
   `sre-agent.bicep` deliberately does *not* contain per-alert triage tables or exact
   SQL/kubectl commands. It points the agent at the diagnostic surface and the KB's
   failure-mode patterns, then asks it to reason. Preserve this when adding/modifying
   skills unless the use case is genuinely deterministic (e.g., parameter tuning with
   no diagnostic surface). See AGENTS.md "Non-Obvious Things" for the full rationale.
