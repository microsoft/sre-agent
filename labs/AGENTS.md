# AGENTS.md — Authoring a Zava Unlimited lab

> Audience: AI assistants (Copilot CLI, Claude Code, Cursor, VS Code Copilot,
> GitHub Copilot Workspace) helping a human contributor add a new lab to the
> Zava Unlimited SRE Agent demo platform.

This file is the universal contract. Read it end-to-end before generating any
files. The human contributor will paste a prompt like:

> "Help me add a new lab for Azure SQL connection-pool exhaustion."

Your job: interview them, then scaffold a working lab they can `azd up`.

## Platform shape

Every lab lives in `labs/<lab-name>/` and provides:

| File | Required | Purpose |
|---|---|---|
| `lab.yaml` | ✅ | Manifest — see `_platform/schema/lab.schema.json` |
| `azure.yaml` | ✅ | azd entrypoint with pre/postprovision hooks |
| `infra/main.bicep` | ✅ | Subscription-scoped bicep that creates RG + resources |
| `scripts/check-environment.ps1` | ✅ | preprovision: prereq + prompt collection (reads `lab.yaml`) |
| `scripts/post-provision.ps1` | ✅ | postprovision: image build, srectl apply, write `.deployed/<name>.json`, optionally launch sim |
| `scripts/scenarios/*.ps1` (or `.py`/`.sh`) | ⚪ | One file per break/fix scenario declared in `lab.yaml` |
| `simulator/` | ⚪ | Lab's own rich sim UI (the meta-sim's `sim.command` points here) |
| `README.md` | ✅ | First non-blank, non-heading line is the launcher's description |

## Contract: lab.yaml

Read the full schema at `_platform/schema/lab.schema.json`. Annotated example
at `_platform/schema/lab.example.yaml`. Key points:

- `name` must equal the directory name (kebab-case)
- `prereqs` lists CLI tools that must be on PATH (e.g. `az`, `azd`, `srectl`)
- `prompts` declares values the launcher collects interactively and stashes in
  azd env (use SCREAMING_SNAKE for `name`)
- `scenarios[].runner` is a path relative to the lab root; the meta-sim shells
  out to it. `.ps1` runs in pwsh, `.py` in python, `.sh` in bash.
- `sim.command` + `args` is how the meta-sim launches the lab's own rich UI

## Contract: post-provision.ps1

The one **mandatory** thing this script must do at the end of a successful
deploy is write `.deployed/<lab-name>.json` with at minimum:

```json
{
  "name": "<lab-name>",
  "deployedAt": "<ISO timestamp>",
  "subscriptionId": "<sub>",
  "resourceGroup": "<rg>",
  "region": "<location>"
}
```

Add any extra fields the lab's sim or scenarios need (e.g. `sreAgentName`,
`portalUrl`, `containerRegistryName`). The meta-sim and scenario runners read
this file to know what's deployed and where.

If `$env:LAB_NO_AUTOLAUNCH` is set, do NOT launch the sim at the end (the
multi-lab launcher sets this to avoid blocking).

## Authoring flow — what to ask the contributor

Don't ask everything at once. Ask in this order:

1. **What does this lab demonstrate?** (one sentence)
2. **Lab name** (kebab-case, e.g. `zava-fintech`) and **subsidiary** (e.g.
   `Zava Fintech` for the displayName/branding)
3. **What Azure compute?** (AKS, ACA, VM, App Service, Functions, …) — this
   shapes `infra/main.bicep`
4. **What sample app?** (existing image? new code in `src/`? none / infra-only?)
5. **What integrations?** (ServiceNow, GitHub, Datadog, …) — each adds a
   prompt and likely a connector + secret
6. **What scenarios?** Get 3-8 break/fix scenarios. For each:
   - id (kebab-case)
   - what breaks
   - what the agent should do
   - approximate runtime
7. **Any non-Azure prereqs?** (`docker`, `srectl`, `kubectl`, `helm`, …)

Then:

1. Run `pwsh ./labs/lab.ps1 -New <lab-name>` — this drops the skeleton
2. Edit `lab.yaml` to fill in prereqs, prompts, scenarios collected above
3. Edit `infra/main.bicep` for the resources implied by step 3-5
4. For each scenario, create `scripts/scenarios/<id>.ps1` from the example
   template (it shows the polling-for-thread-URL pattern)
5. Validate: `python _platform/helpers/manifest.py validate <lab>/lab.yaml`
6. Test discovery: `pwsh ./labs/lab.ps1 -List` should show the new lab
7. (Optional) Deploy: `./lab.sh -Labs <lab-name>`

## Reference labs to mimic

- `zava-power/` — full ACA + ServiceNow + 8 scenarios. Best reference for
  complex labs with rich integrations.
- `zava-athletic/` — simpler AKS+Postgres lab with 3 scenarios. Best
  reference for single-domain labs.

## Hard rules — do not violate

- **Never modify `_platform/`** without an explicit ask from the human. That's
  the platform itself; lab-author flow only adds new lab dirs.
- **Never overwrite an existing lab dir.** If `<lab-name>` exists, ask the
  human to pick a different name or explicitly confirm they want to delete.
- **Never commit secrets.** Prompts with `secret: true` go to azd env at
  deploy time; they must NOT be hardcoded into bicep, scripts, or yaml.
- **Bicep must be subscription-scoped** (`targetScope = 'subscription'`) and
  create its own RG. azd assumes this.
- **`.deployed/` is gitignored.** Don't reference it from code that runs
  before deploy. It only exists post-provision.

## When you finish

Tell the human:

```
Lab '<name>' scaffolded. Next steps:
1. Review labs/<name>/lab.yaml and labs/<name>/infra/main.bicep
2. Implement scenario runners in labs/<name>/scripts/scenarios/
3. Validate:  python labs/_platform/helpers/manifest.py validate labs/<name>/lab.yaml
4. Deploy:    cd labs && ./lab.sh -Labs <name>
```

If you're a Copilot CLI user, the `lab-author` skill (in `.github/extensions/`)
wraps this whole flow with adaptive Q&A — use it instead of doing this manually.
