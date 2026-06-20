# Zava Unlimited

A growing collection of Azure SRE Agent demo labs, all deployable through one
launcher and breakable through one meta-simulator.

> Zava is a fictional retail conglomerate. Each subsidiary (Zava Power, Zava
> Athletic, Zava Cafe, Zava Eats, Zava IT Support, Zava Infra) is a
> self-contained lab that demonstrates a different Azure workload + SRE Agent
> autonomy story.

## TL;DR

```bash
./lab.sh           # POSIX — pick one or more labs to deploy
pwsh ./lab.ps1     # Windows / cross-platform
./sim.sh           # POSIX — pick a deployed lab + scenario to break/fix
pwsh ./sim.ps1
```

## Two top-level commands

| Command | Purpose |
|---|---|
| `lab.ps1` / `lab.sh` | Discover labs, prompt for inputs, run `azd up` |
| `sim.ps1` / `sim.sh` | Discover **deployed** labs, run break/fix scenarios |

## Currently shipping

| Lab | Subsidiary | Workload |
|---|---|---|
| `zava-power/` | Zava Power | ACA + ServiceNow utility ops, 8 scenarios |
| `zava-athletic/` | Zava Athletic | AKS + PostgreSQL e-commerce, 3 scenarios |
| `zava-cafe/` | Zava Cafe | App Service + Azure SQL specialty-coffee e-commerce |
| `zava-eats/` | Zava Eats | Starter lab — Grubify food-ordering sample, first break/fix |
| `zava-itsupport/` | Zava IT Support | ACA — IT helpdesk + ServiceNow MCP |
| `zava-infra/` | Zava Infra | 3 scenarios — tf-drift, perf-drift, compliance |

Run `pwsh ./lab.ps1 -List` for the live list.

## Authoring a new lab

Two paths:

1. **Conversational, in Copilot CLI:** install the `lab-author` skill (under
   `.copilot/extensions/lab-author/`) and just say "Help me add a new lab to
   Zava Unlimited". The skill will interview you and call the scaffolder.
2. **Manual / any AI assistant:** read `AGENTS.md` for the contract, then run
   `pwsh ./lab.ps1 -New <kebab-name>` for the skeleton.

The platform is in `_platform/` — schema, helpers, template. Don't modify it
when adding a lab; just drop a new sibling directory.

## Multi-lab launcher (`lab.ps1`)

Interactive picker by default:

```
Which lab(s) do you want to deploy?
  [1] zava-power            ACA + ServiceNow utility-platform demo with 8 break/fix scenarios.
  [2] zava-athletic         AI-first AKS + PostgreSQL e-commerce demo with 3 break/fix scenarios.
  [3] zava-eats             Starter lab — Grubify food-ordering sample, first break/fix.
  [a] all
  [q] quit
```

Pick one, several (comma-separated), or `a` for all. Each lab gets its own
azd environment so they coexist cleanly.

### Non-interactive

```bash
./lab.sh -Labs zava-power                 # deploy one
./lab.sh -Labs zava-power,zava-athletic       # deploy multiple
./lab.sh -List                            # list available labs
./lab.sh -Down zava-power                 # tear down
./lab.sh -New my-new-lab                  # scaffold a new lab
```

### Behavior

- **Single-lab deploy** auto-launches the simulator at the end of postprovision.
- **Multi-lab deploy** sets `LAB_NO_AUTOLAUNCH=1` so postprovision finishes
  cleanly; launch sims manually after via `./sim.sh -Lab <name>`.
- Deploys run sequentially (azd serializes resource state anyway).

## Meta-simulator (`sim.ps1`)

After one or more labs are deployed (each writes
`.deployed/<lab>.json` from its post-provision), `sim` discovers them:

```bash
./sim.sh                                  # interactive: pick a deployed lab
./sim.sh -List                            # list deployed labs + their scenarios
./sim.sh -Lab zava-power                  # run that lab's full sim UI
./sim.sh -Scenario zava-power db-outage   # run one scenario directly
```

If only one lab is deployed, `sim` enters its UI directly. If multiple are
deployed, you get a picker that includes a unified "scenarios across all
labs" view.

## Anatomy of a lab

```
labs/<name>/
├── lab.yaml                 # manifest (schema in _platform/schema/)
├── azure.yaml               # azd entrypoint w/ pre+postprovision hooks
├── infra/main.bicep         # subscription-scoped IaC
├── scripts/
│   ├── check-environment.ps1   # preprovision: prereqs + prompts → azd env
│   ├── post-provision.ps1      # image build, srectl apply, write .deployed/
│   └── scenarios/<id>.ps1      # one runner per scenario in lab.yaml
├── simulator/               # (optional) lab's own rich UI
└── README.md
```

See `AGENTS.md` for the full contract and `_platform/schema/lab.example.yaml`
for an annotated manifest.
