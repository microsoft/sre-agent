---
name: managing-sre-agent
description: "Manage Azure SRE Agent configuration for this demo: connectors, skills, guarded custom agents, response plans, and the knowledge base. Use when asked to create, list, update, or delete SRE Agent resources."
---

# SRE Agent Administration

For **this demo**, core agent configuration is declared in Bicep
(`infra/modules/sre-agent.bicep`):

- **Agent settings** — autonomous mode, High access level, Azure Monitor incident binding
- **RBAC** — system-assigned managed identity granted Reader, Monitoring Reader,
  Contributor, and AKS RBAC Cluster Admin on the resource group; the runtime
  user-assigned identity also has subscription-level Reader so the
  correlation skill can read Alerts Management and Resource Health event feeds

To change these resources, **edit the Bicep and run `azd provision`**.

The four connectors (`app-insights`, `log-analytics`, `azure-monitor`, and
`learn-docs`) are declared under `connectors` in `sre-config/agent-config.json`.
Setup applies them using `infra/modules/sre-agent-connectors.bicep` after an
authenticated API-readiness gate. Do not put them back in the core agent module:
that would block post-provision recovery while the backend is still starting.

Runtime skills, custom agents, and response plans are defined in
`sre-config/agent-config.json`. Skill procedures live in `sre-config/skills/`;
agent definitions live in `sre-config/agents/`.
`scripts/setup-sre-agent.ps1` renders these and embeds the shared
`sre-config/hooks/readonly-evidence.py` into each child's hook.
This `.github/skills/` document is operator guidance, not a deployed runtime skill.

Do not design overlapping response plans around an assumed priority or
specificity rule. Treat multiple matches as undefined, keep purpose-built
filters mutually exclusive where routing matters, and make any fallback both
positively scoped and explicitly exclude every known route.

## Post-provision configuration

Run:

```powershell
.\scripts\setup-sre-agent.ps1
```

Only run that command with authorization to modify live configuration. For a
local-only preview, use `-ResourceGroup rg-example -RenderOnly`; it does not
authenticate or make network calls.

The script waits for API readiness, applies the staged connector template through
ARM, checks evidence-tool registration, and applies and reads back skills,
then agents/hooks, then response plans. It refuses to publish the global routing
hint until referenced skills and agents converge.
It also uploads knowledge files, syncs agent-global custom instructions, and
enables the Microsoft Learn MCP tools.

Matching skills, agents, response plans, and instructions skip writes. If a managed
definition or nonempty global instructions differ from source, setup stops before
writes. Inspect the live definition
and the reported changed fields; only then explicitly rerun with `-UpdateExisting`.
The script first saves previous managed definitions/instructions to the user's
local application-data `sre-agent/snapshots` directory, or `-SnapshotDirectory`
outside any Git checkout. Never commit those private snapshots. It preserves
unmanaged objects and tags; there is no prune mode. Existing agents use PATCH to
preserve settings outside the lab manifest. Rereads detect edits since preflight,
but this is not a transactional multi-object deployment.

Connectors retain incremental Bicep apply semantics, preserving unmanaged names
and existing tags. Source IDs and some connector fields are redacted by the API;
only exposed type, identity, and provisioning state are compared. Changing an
existing type/identity requires `-UpdateExisting`; other declared connector
settings are reapplied from source. Do not describe redacted snapshots as a
complete rollback backup.

`-ReadinessTimeoutSeconds` (default 900) bounds startup polling;
`-ConnectorTimeoutSeconds` (default 600) bounds the connector deployment and its
transient retries. Authentication failures stop immediately. On deployment timeout,
setup requests cancellation; inspect the reported deployment before retrying.

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

## Evidence skills and specialists

`zava-investigation-coordination` guides the meta agent, not a new incident
handler. It owns no operational cloud tools. The two `zava-*-evidence` skills own
read-only procedures and the two Monitor dependency names in manifest `tools`.
That array becomes the JSON API's `properties.tools`; Markdown frontmatter alone
is insufficient. Application/performance incident runbooks reuse the evidence
skills while retaining their authorized write tools and remediation sections.

The named specialists have nonempty `handoffDescription`, selected evidence
skills, explicit `tools: ["ReadFile"]`, and child-only PreToolUse guards. Do not
empty all agent tool lists (workspace defaults can return), empty `allowedSkills`
(not a deny-all control), or install the guard globally. A hook pass must not
emit `permissionDecision: allow`. Adding a skill dependency must not silently
widen the guard's exact allowlist.

Default `SkillOwned` mode declares Monitor dependencies on the evidence skills.
`-EvidenceToolMode ExplicitAgent` also selects them on the specialists for
compatibility. Do not change a working profile's tool mode without confirming
the selected skill and tools are available on that deployment.

Run the local contracts with
`python -B -m unittest discover -s .\tests -p 'test_*.py' -v` (Python 3 and
PowerShell 7.4+, no packages). Follow the
[configuration verification guide](../../../docs/skills-agents-validation.md)
after an authorized deployment. Local tests do not establish live tool availability.

## When helping users

1. **"Add a skill or response plan"** — edit `sre-config/agent-config.json`
   and the relevant file under `sre-config/skills/`, then run
   `setup-sre-agent.ps1`.
2. **"Add a connector"** — edit the manifest's `connectors` entries and run
   `setup-sre-agent.ps1` after reviewing the change. Connector resources remain
   ARM/Bicep-managed through the staged template.
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
8. **"Add an evidence specialist"** — add a manifest `agents` reference and a
   supported properties file; reuse the child hook, not a global hook. Preview
   locally first. Do not change response-plan handlers, IAM, connectors, network
   access, or self-management settings as part of this configuration change.
