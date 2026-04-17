# Terraform Drift Detection with Azure SRE Agent

**Detect drift. Correlate with incidents. Remediate intelligently.**

An end-to-end demo showing how Azure SRE Agent autonomously investigates Terraform infrastructure drift — triggered by a single webhook via HTTP Triggers.

> **Blog post**: [Event-Driven IaC Operations with Azure SRE Agent: Terraform Drift Detection via HTTP Triggers](https://techcommunity.microsoft.com/blog/sre-agent-terraform-drift-detection) <!-- Update with actual URL after publishing -->

---

## What This Demo Does

A Terraform Cloud run notification (or simulated webhook) triggers the SRE Agent to:

1. **Detect drift** — Compare Terraform config against actual Azure resource state
2. **Correlate with incidents** — Query Application Insights and Activity Log to understand *why* the drift happened
3. **Classify severity** — Benign (tags), Risky (TLS downgrade), Critical (SKU change)
4. **Investigate root cause** — Read application source code from the connected GitHub repo
5. **Recommend smart remediation** — Context-aware: "Do NOT revert the SKU while the latency bug is still deployed"
6. **Notify the team** — Post a structured drift report to Microsoft Teams
7. **Improve its own skill** — Self-review and update the drift analysis runbook
8. **Ship a fix** — Create a PR to address the root cause

## Architecture

```
Terraform Cloud  ──webhook──▶  Azure Logic App  ──authenticated POST──▶  SRE Agent HTTP Trigger
(drift detected)               (auth bridge)                              (autonomous investigation)
                               Managed Identity
                               acquires Azure AD token
```

## Repository Structure

```
├── app/
│   ├── server.js                  # Demo Node.js app (with intentional latency bug)
│   └── package.json
├── terraform/
│   ├── main.tf                    # App Service, App Insights, Log Analytics
│   ├── logic-app.tf               # Logic App auth bridge (webhook → SRE Agent)
│   ├── providers.tf               # AzureRM provider config
│   ├── variables.tf               # Input variables with sensible defaults
│   ├── outputs.tf                 # URLs, resource names, identity IDs
│   └── terraform.tfvars.example   # Copy to terraform.tfvars and fill in your values
├── scripts/
│   ├── deploy-app.ps1             # Deploy the demo app to App Service
│   ├── generate-load.ps1          # Generate latency data in Application Insights
│   ├── induce-drift.ps1           # Create 3 types of drift (tags, TLS, SKU)
│   ├── simulate-tfc-notification.ps1  # Send a simulated TFC webhook
│   └── revert-drift.ps1           # Undo all drift changes
├── skills/
│   └── terraform-drift-analysis.md    # Agent skill: drift classification & remediation
└── IMPLEMENTATION-GUIDE.md        # Step-by-step setup guide (assumes no prior IaC knowledge)
```

## Quick Start

### Prerequisites

- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- [Terraform](https://developer.hashicorp.com/terraform/install) (≥ 1.5)
- [PowerShell 7+](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell)
- An Azure subscription with Contributor access
- An [Azure SRE Agent](https://sre.azure.com) instance

### Steps

```powershell
# 1. Clone and configure
git clone https://github.com/surivineela/sre-agent.git
cd sre-agent/samples/terraform-drift-detection/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your subscription ID

# 2. Deploy infrastructure
terraform init
terraform apply

# 3. Deploy the demo app
cd ../scripts
.\deploy-app.ps1

# 4. Create the skill and HTTP Trigger in SRE Agent (see IMPLEMENTATION-GUIDE.md Steps 3-6)

# 5. Generate load (creates incident data in App Insights)
.\generate-load.ps1

# 6. Induce drift
.\induce-drift.ps1

# 7. Trigger the agent
$url = terraform output -raw logic_app_callback_url
.\simulate-tfc-notification.ps1 -LogicAppCallbackUrl $url

# 8. Watch the investigation in SRE Agent!
```

For the full walkthrough with screenshots and detailed explanations, see the **[Implementation Guide](IMPLEMENTATION-GUIDE.md)**.

## The 3 Drift Types

| Type | Change | Real-World Scenario | Agent Classification |
|------|--------|--------------------|--------------------|
| **Benign** | Tags: `manual_update=true`, `changed_by=portal_user` | Finance adds cost-center tags in the Portal | Safe to revert anytime |
| **Risky** | TLS minimum version: 1.2 → 1.0 | Someone downgrades security while troubleshooting | Revert immediately |
| **Critical** | App Service Plan SKU: B1 → S1 | On-call scales up during a latency incident | **Do NOT revert** until root cause is fixed |

## What Makes This Different

| Traditional drift detection | This demo |
|---|---|
| Tells you *what* changed | Tells you *who* changed it, *why*, and *whether it's safe to revert* |
| Outputs a diff | Outputs a severity-classified report with incident correlation |
| Sends an alert | Sends an investigation with smart remediation recommendations |
| Requires human triage | Agent triages autonomously, notifies via Teams, ships a PR |

## Clean Up

```powershell
# Revert drift
cd scripts
.\revert-drift.ps1

# Destroy all Azure resources
cd ../terraform
terraform destroy
```

## License

MIT

## Related

- [Azure SRE Agent Documentation](https://sre.azure.com/docs)
- [HTTP Triggers Documentation](https://sre.azure.com/docs/http-triggers)
- [Other SRE Agent Samples](../README.md)
