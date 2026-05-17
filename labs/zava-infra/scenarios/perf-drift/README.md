# Zava Infra — VM + CosmosDB Performance Drift

Linux VM workload talking to Azure CosmosDB. When VM CPU/disk pressure builds up or CosmosDB starts throttling, Azure Monitor alerts fire and the SRE Agent investigates, diagnoses the root cause, and proposes remediation — including an approval hook before scaling actions.

## Stack

- **App**: Node.js workload (`src/app.js`) running on a Linux VM. Reads/writes to a CosmosDB container in a steady-state loop. Designed to surface VM CPU pressure (when CPU is artificially loaded) or DB-side throttling (when RU/s is exhausted).
- **Compute**: Azure VM (Linux) + Azure CosmosDB (SQL API)
- **Networking**: VNet + NSG (`infra/modules/network.bicep`)
- **Data**: CosmosDB account (`infra/modules/cosmosdb.bicep`) — provisioned-throughput container, low default RU/s to make throttling demos easy
- **Observability**: Log Analytics Workspace + Azure Monitor metric alerts for VM CPU, VM disk IOPS, CosmosDB throttled requests (`infra/modules/monitoring.bicep`)
- **SRE Agent**: `Microsoft.App/agents` instance (`infra/modules/sre-agent.bicep`) with two custom skills (`vm-performance-diagnostics`, `compliance-drift-detection`), an approval hook (`hooks/vm-remediation-approval.yaml`) gating any scale/restart action, and a scheduled `compliance-drift-scan` task
- **Simulator**: Bash break/fix scripts under `scripts/` — `break-vm.sh` (drives CPU/disk pressure), `break-db.sh` (CosmosDB throttling/config drift)
- **CI/CD**: `azd up` (Bicep + Bash post-deploy via `scripts/post-deploy.sh` and `scripts/install-app.sh`)

## What it's about

This scenario is for SREs and platform engineers who want to see how the **Azure SRE Agent diagnoses workload-level performance drift** — the gap between what your service should be doing and what telemetry shows it actually doing — and recommends a remediation path that requires human approval before mutating production. Two failure modes are pre-built: VM-side resource pressure (CPU/disk) and DB-side throttling (CosmosDB RU/s exhaustion or config drift). For each, the agent reads the relevant Azure Monitor metrics, correlates with VM Insights and CosmosDB diagnostics, identifies whether the root cause is workload, configuration, or scale, and surfaces a specific recommendation (scale up, increase RU/s, fix a config drift) — but pauses on `vm-remediation-approval` before taking action.

The scenario teaches: metric-driven investigation, multi-source correlation (VM + DB + workload), approval-gated remediation, and recurring compliance-drift scanning (tags, SKU, networking baseline) every 30 min.

## Quick start

```bash
cd labs/zava-infra/scenarios/perf-drift
azd up
# postprovision wires up: post-deploy.sh (skill+hook+task) and install-app.sh (workload on VM)

# Trigger VM pressure (~6 min run)
bash scripts/break-vm.sh

# OR trigger CosmosDB drift (~6 min)
bash scripts/break-db.sh
```

Watch the SRE Agent thread fire on the alert, run the diagnostic skill, and propose a remediation pending your approval.

## Demo scenarios (from `lab.yaml`)

| ID | Label | Runner | Length |
|---|---|---|---|
| `vm-pressure` | VM CPU/disk pressure | `scripts/break-vm.sh` | ~6 min |
| `db-fault` | CosmosDB throttling / config drift | `scripts/break-db.sh` | ~6 min |

## Files of note

- `infra/main.bicep` — subscription-scope deployment entry point
- `infra/modules/{vm,cosmosdb,network,monitoring,sre-agent,roles}.bicep` — modular infra
- `skills/vm-performance-diagnostics/SKILL.md` — VM-side runbook the agent uses
- `skills/compliance-drift-detection/SKILL.md` — drift baseline policy
- `hooks/vm-remediation-approval.yaml` — approval gate for any scale/restart action
- `scheduled-tasks/compliance-drift-scan.yaml` — periodic drift scanning
- `scripts/break-vm.sh`, `scripts/break-db.sh` — break-path simulators
- `scripts/install-app.sh` — installs Node.js workload on the VM after provision
