# Release on SRE Fix

## When to use
Triggered by `BuildSucceeded` events on the **PowerGrid-Build**
pipeline. The release-orchestrator agent loads this skill on every
such event.

## Why a filter is necessary
ADO release triggers do not natively filter by author or commit tag.
Without this skill, every successful build (including human dev
commits) would auto-release. We want auto-release ONLY for SRE-Agent
fixes that have already been validated by the agent's own diagnosis.

## Configuration (lab-specific — edit for your environment)
- **SRE Agent service principal UPN** (used to identify SRE-authored
  builds when the `sre-agent-fix` tag is missing): set this in your
  agent prose, e.g. `sre-agent@yourtenant.onmicrosoft.com`. If your
  PR-creation flow always tags the resulting build with
  `sre-agent-fix`, the SP UPN check is optional.
- **Build pipeline name**: `PowerGrid-Build`.
- **Release pipeline name**: `PowerGrid-Release`.

The built-in ADO MCP tools accept either pipeline names or numeric
IDs; prefer names so this skill is portable across environments
where the IDs differ.

## Decision flow

### 1. Read the build
Use the built-in ADO MCP tool **`GetPipelineRunHistory`** on the
**PowerGrid-Build** pipeline, filtered to the run that triggered the
event. Capture:
- `tags` (array of strings)
- `requestedFor.uniqueName`
- `result` (must be `succeeded`)

### 2. Idempotency check
If `tags` already contains a value matching `sre-agent-release-*`, a
release has already been triggered for this build. Post Teams note
"release already in flight" and EXIT.

### 3. Determine is_sre_agent_fix
```
is_sre_agent_fix =
  ('sre-agent-fix' in tags)
  OR
  (requestedFor.uniqueName.lower() == SRE_AGENT_SP_UPN.lower())
```

### 4. Decision matrix

| `result == succeeded` | `is_sre_agent_fix` | Action |
|---|---|---|
| no  | any   | Post Teams note "build N did not succeed; nothing to release", exit. |
| yes | false | Post Teams note "Build #N succeeded — human-author build, leaving release to normal CI/CD", exit. |
| yes | true  | Proceed to step 5. |

### 5. Trigger PowerGrid-Release
Use the built-in ADO MCP run-pipeline tool (the same one the
pipeline-failure-investigator agent uses for `TriggerBuildPipelineRun`
— there is an equivalent for the release pipeline) to start the
**PowerGrid-Release** pipeline with variables:
- `SOURCE_BUILD_ID = <build_id>`
- `TRIGGERED_BY    = sre-agent`
- `REASON          = auto-release of SRE-Agent fix for buildId=<id>`

Then add an audit tag to the SOURCE build (best-effort): tag value
`sre-agent-release-<release_id>`. Use the built-in ADO MCP add-tag
tool.

### 6. Post to Teams
"🤖 Auto-release triggered: PowerGrid-Release run #&lt;release_id&gt;
materializing SRE-Agent fix from build #&lt;build_id&gt;. The
deployment-validator agent will validate post-deploy."

EXIT. The deployment-validator agent picks up from ReleaseSucceeded.

## Why no custom PythonTool
The SRE Agent runtime exposes ADO operations through built-in MCP
tools that are pre-authenticated via delegated OAuth. Custom
PythonTools that call ADO directly require either a PAT (a secret to
manage) or the agent's managed identity to be added as a user in the
ADO org (extra setup). Built-in MCP tools require neither.

## Loop-safety notes
- Never trigger a release for a build that wasn't tagged — even if
  the build originated from an SRE-Agent-authored commit, untagged
  builds suggest something is off; let humans investigate.
- Never trigger a release if `result != succeeded`.
- Do not chain triggers: this agent does not trigger another build
  from a release (the deployment-validator handles rollback +
  fix-PR + new build chain on regression).
