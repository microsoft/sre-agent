# AGENTS.md — PowerGrid ZeroOps lab

Guidance for any AI agent working in this lab directory.

PowerGrid ZeroOps demo — Azure Container Apps utility-platform with break/fix
scenarios, two SRE Agent instances (ops + IT support), ServiceNow integration,
and a rich simulator that drives end-to-end scenarios.

## Getting started

When a user clones this repo, guide them through setup:
1. Run the prereq check: from `labs/`, `pwsh ./_platform/check-prereqs.ps1` —
   this verifies `az`, `azd`, `python`, `pwsh`, and `srectl`. Note that
   `srectl` is currently a Microsoft private preview tool — public users will
   see it flagged as missing.
2. From `labs/`, run `pwsh ./lab.ps1 -Labs zava-power`. The launcher does
   the prereq check, prompts for any missing manifest values, then runs
   `azd up` which deploys the Bicep infrastructure.
3. After Bicep finishes, the postprovision hook (`scripts/post-provision.ps1`)
   does: render `sre-config/` placeholders, apply rendered yaml via `srectl`,
   write `.deployed/zava-power.json`, install simulator deps.
4. If `srectl` is missing OR `LABS_SKIP_SRECTL=1` was set during the prereq
   gate, post-provision skips the apply step cleanly — Azure resources are
   still deployed but you'll need to apply the SRE Agent config manually
   once you get private-preview access.
5. Open the simulator: `python simulator/demo.py` — pick a scenario.
6. Watch the SRE Agent thread URL the simulator prints; it polls for
   triggered investigations and surfaces the link.

## Non-obvious gotchas

- **`sre-config/` is parameterized.** Files contain `{{PLACEHOLDERS}}` that
  `scripts/post-provision.ps1` substitutes from azd env vars. Never hand-edit
  the rendered output — edit `sre-config/` and re-run post-provision.
- **One SRE Agent instance.** The bicep deploys `sre-zavapower-ops`, which
  receives the full `srectl apply` pass for the agents in `sre-config/`.
- **ServiceNow MCP connector requires a paid PDI** (not a trial) for the full
  flow — trial PDIs have rate-limit headers that throttle the agent's writes.
  Setup script prompts for PDI URL + credentials.
- **HTTP triggers preferred over scheduled tasks** for the pod-audit scenario.
  Scheduled tasks fire on a clock; HTTP triggers fire when the simulator
  injects a fault, so demos are deterministic.
- **The simulator polls SRE Agent** to find the triggered thread and prints
  the URL. Don't change this to "wait N seconds" — agent startup time varies.
- **`bugs/` directory holds failure payloads** injected by the build pipeline
  via `failure_scenario` parameter. Don't move or rename without updating
  the ADO `pipelines/build.yml`.
- **Top-level `skills/` is duplicate of `sre-config/skills/`** — only
  `sre-config/skills/` is canonical and gets applied by srectl. Removing the
  top-level dupe is a TODO before this lab merges upstream.

## Where the recipes live

`sreagent-templates/recipes/azmon-aca-servicenow-powergrid-ops/`
is derived from `sre-config/` via
`https://github.com/sandeepaziz/ppl-zeroops-lab/blob/main/setup/generate-recipes.py`.
Re-run that generator whenever `sre-config/` changes if you want to keep the
recipes in sync.
