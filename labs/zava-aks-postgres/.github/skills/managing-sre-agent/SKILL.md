---
name: managing-sre-agent
description: "Manage Azure SRE Agent configuration for this demo: connectors, skills, response plans, and the knowledge base. Use when asked to create, list, update, or delete SRE Agent resources."
---

# SRE Agent Administration

For **this demo**, core agent configuration is declared in Bicep
(`infra/modules/sre-agent.bicep`):

- **Agent settings** — autonomous mode, High access level, Azure Monitor incident binding
- **Connectors** — `app-insights`, `log-analytics`, `azure-monitor` (MonitorClient), `learn-docs` (Microsoft Learn no-auth MCP)
- **RBAC** — system-assigned managed identity granted Reader, Monitoring Reader,
  Contributor, and AKS RBAC Cluster Admin on the resource group; the runtime
  user-assigned identity also has subscription-level Reader so the
  correlation skill can read Alerts Management and Resource Health event feeds

To change these resources, **edit the Bicep and run `azd provision`**.

Custom skills and response plans are defined in
`sre-config/agent-config.json` and `sre-config/skills/`. They are applied by
`scripts/setup-sre-agent.ps1`.

Do not design overlapping response plans around an assumed priority or
specificity rule. Treat multiple matches as undefined, keep purpose-built
filters mutually exclusive where routing matters, and make any fallback both
positively scoped and explicitly exclude every known route.

## Post-provision configuration

Run:

```powershell
.\scripts\setup-sre-agent.ps1
```

The script applies skills and response plans, then verifies their properties.
It also uploads knowledge files, syncs agent-global custom instructions, and
enables the Microsoft Learn MCP tools.

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

Keep global instructions short; detailed procedures belong in a skill so they
load only when relevant.

## When helping users

1. **"Add a skill or response plan"** — edit `sre-config/agent-config.json`
   and the relevant file under `sre-config/skills/`, then run
   `setup-sre-agent.ps1`.
2. **"Add a connector"** — edit `infra/modules/sre-agent.bicep` and run
   `azd provision`.
3. **"Add a knowledge file"** — drop the markdown under
   `sre-config/knowledge-base/` and run `setup-sre-agent.ps1`.
4. **"Verify the agent is configured"** — run `setup-sre-agent.ps1`; Step 7
   verifies the deployed properties.
5. **Activity-log alerts gotcha** — they fire as Sev4 regardless of the configured
   severity, so response plan filters must match all severities.
6. **Runbook philosophy** — preserve the existing descriptions, tools, and
   procedures when moving or editing files under `sre-config/skills/`.
7. **Kubernetes tool guidance** — use `RunKubectlReadCommand` and
   `RunKubectlWriteCommand` directly in runtime skills. Do not make runbooks
   depend on terminal-native kubectl.
