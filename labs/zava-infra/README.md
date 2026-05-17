# Zava Infra — Infrastructure Operations & Governance

Multi-scenario lab showing how Azure SRE Agent investigates **three forms of infra drift**: Terraform drift, performance drift, and deployment-compliance drift.

## Stack

- **Compute**: Mixed — Azure App Service (tf-drift), Azure VM + CosmosDB (perf-drift), Azure Container Apps (compliance). Each scenario provisions independently.
- **IaC**: Mixed — Terraform (tf-drift), Bicep + `azd` (perf-drift and compliance).
- **Observability**: Per-scenario. Common: Log Analytics + Application Insights + Azure Monitor / Activity Log alerts.
- **SRE Agent**: One agent per scenario (or share an existing instance for tf-drift). Custom skills: `terraform-drift-analysis`, `deployment-compliance-check`. HTTP triggers, response plans, scheduled tasks, approval hooks.
- **Simulator**: Per-scenario break/fix scripts (PowerShell for tf-drift and perf-drift; manual Portal edit + Activity Log for compliance).
- **CI/CD**: `terraform apply` (tf-drift) or `azd up` (perf-drift, compliance); see each scenario's README.

## What it's about

This lab is for PMs, SREs, platform engineers, and governance/security teams. The unifying theme is **infra drift** — anywhere your infrastructure's actual state diverges from the expected state, regardless of whether the cause is malicious, accidental, or organic. Each scenario shows how the Azure SRE Agent can autonomously detect, diagnose, classify, and recommend remediation for one specific drift class:

| Scenario | Drift class | Signal | What the agent does |
|---|---|---|---|
| **tf-drift** | IaC config diverged from reality | Terraform Cloud webhook → Logic App → HTTP trigger | Classifies drift (Benign / Risky / Critical), correlates with App Insights latency, recommends safe revert |
| **perf-drift** | Workload metrics diverged from SLO | Azure Monitor alert (VM CPU / Cosmos throttling) | Reads metrics, finds root cause, suggests scale or query-plan changes |
| **compliance** | Deploys bypass CI/CD policy | Activity Log alert on Container App writes | Classifies caller (Portal / CLI / service principal), flags non-compliant changes, waits for human approval to revert |

## Scenarios

Each scenario is independently deployable from its own directory:

- [`scenarios/tf-drift/`](scenarios/tf-drift/) — Terraform drift detection (Terraform-provisioned; webhook-driven)
- [`scenarios/perf-drift/`](scenarios/perf-drift/) — VM + CosmosDB performance drift (Bicep + `azd`)
- [`scenarios/compliance/`](scenarios/compliance/) — Deployment compliance (Bicep + `azd`)

## Quick start

```bash
# Each scenario has its own deploy command. Pick one:

# tf-drift (Terraform)
cd labs/zava-infra/scenarios/tf-drift
terraform init && terraform apply
# Then see scenarios/tf-drift/README.md for the demo flow

# perf-drift (azd)
cd labs/zava-infra/scenarios/perf-drift
azd up

# compliance (azd)
cd labs/zava-infra/scenarios/compliance
azd up
bash scripts/post-deploy.sh
```

See each scenario README for full break/fix walkthrough.
