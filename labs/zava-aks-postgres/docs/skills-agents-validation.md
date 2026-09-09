# Verify skill and agent configuration

Use this guide after an authorized configuration update. Use existing telemetry;
configuration verification does not require fault injection, application changes,
new permissions, or incident closure.

## Preview locally

From the lab directory:

```powershell
.\scripts\setup-sre-agent.ps1 -ResourceGroup rg-example -RenderOnly
python -B -m unittest discover -s .\tests -p 'test_*.py' -v
```

The preview does not authenticate or contact Azure. It renders nine skills, two
custom agents, and four response plans. Each evidence skill declares its Monitor
dependencies in `properties.tools`. Each specialist selects its domain skill,
`ReadFile`, and the shared PreToolUse guard.

## Apply and read back

Inspect existing definitions before running `setup-sre-agent.ps1`. If an existing
managed definition differs from source, the script stops before writes and lists
the affected fields. Review those differences before rerunning with
`-UpdateExisting`. New agents use PUT; existing agents use PATCH to retain
operator settings not managed by the manifest.

Core Bicep provisions the agent and firewall without connectors. Setup waits for
an authenticated configuration API response, then applies
`infra/modules/sre-agent-connectors.bicep` through ARM using the manifest's
connector definitions. Each invocation uses a unique ARM deployment name, retained
across its retries, polling, and cancellation, so an earlier success cannot satisfy
a new submission. It checks Monitor tool registration, applies skills before agents, and
reads back each configuration collection before continuing. Global coordination guidance
is applied only after the referenced skills and agents match source. Reapplying
matching skills/agents/plans/instructions skips writes; unmanaged objects are not
deleted. The connector stage retains incremental Bicep apply semantics.

Readiness retries startup 404/408/429/5xx responses for up to
`-ReadinessTimeoutSeconds` (default 900). Authentication failures stop rather than
being treated as startup. Connector deployment and transient retries are bounded
by `-ConnectorTimeoutSeconds` (default 600), including individual request timeouts.
Transient polling connection failures resume observation of the same deployment.
If setup stops while a deployment may still be running, it attempts cancellation
with a separate 30-second request budget and reports the outcome and ARM deployment
to inspect before retrying. Cancellation does not roll back completed writes.

During `azd up`, post-provision polls a pending ingress IP before starting agent
setup. `post-provision.ps1 -IngressTimeoutSeconds` defaults to 300 seconds;
in-flight AKS command execution can extend the elapsed time. Command errors fail
immediately, and an unassigned IP at expiry stops with retry guidance rather than
reporting deployment success.

Check the resulting configuration:

| Item | Expected result |
|---|---|
| Connectors | ARM deployment succeeded; exposed type/identity/state and required tool registration match. Redacted source/settings are not fully verifiable by readback. |
| Evidence skills | Nonempty descriptions, complete procedures, and the two Monitor tool dependencies |
| Specialists | Correct name, delegation description, selected evidence skill, and explicit `ReadFile` capability |
| Hooks | One child-specific PreToolUse command hook, matcher `(?s:.*)`, timeout 30, fail mode `block`, and the shared script |
| Response plans | Filters, modes, and retry settings match the manifest; handler is `meta_agent`. |
| Existing settings | Operator-selected model and other unrelated agent settings retained |

## Confirm investigation behavior

Use the README's example prompt with your telemetry and PostgreSQL resource IDs
and an absolute UTC window. Confirm that the coordinator delegates independent
questions to the intended specialists, that each reads its assigned skill, and
that each returns source-backed results or explicit access/data limitations.
A simple CPU question should not require parallel investigation.

For supplied reference files, confirm the specialist can read the authorized
path. Review the resulting queries for the correct resource, window, schema, and
`zava-api` role filter. Application Insights `duration` and Log Analytics
`DurationMs` are both numeric milliseconds. Empty data, failed calls, and missing
intervals must remain visible in the result; timing alone does not establish cause.

**Tool availability must be confirmed on the target deployment.** Readback and
local tests verify configuration, not runtime skill loading. Do not remove every
explicit agent tool selection: workspace defaults may then supply tools
independently of skills. If the deployed runtime cannot provide the skill's
dependencies, retain a working configuration or explicitly select
`-EvidenceToolMode ExplicitAgent` after reviewing the change. That compatibility
mode selects Monitor on the agents as well as the skills; it is not an automatic
fallback.

## Recovery and privacy

Before changes, setup saves previous managed definitions and global instructions
to the user's local application-data `sre-agent/snapshots` directory, or the
specified `-SnapshotDirectory` outside Git. Keep snapshots and investigation
output private.
Connector snapshots contain only the fields ARM returns, including redacted
values; they are not complete backups of secret-backed connector configuration.

Updates are not a multi-resource transaction. Avoid concurrent configuration
editors; if a run fails, inspect current state and the saved snapshot before
retrying. For approved rollback, restore the previous writable configuration
through the agent's configuration interface. Review newly created objects
separately before deleting them. Never delete all objects absent from the manifest.
Knowledge-file uploads and Learn tool settings retain their separate sync behavior.
