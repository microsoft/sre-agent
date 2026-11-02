# Cost Management

Deploy an Azure SRE Agent for Azure Cost Management analytics and FinOps operations.

## Prerequisites

- An Azure subscription with Cost Management Reader access
- At least one Azure resource group to monitor
- All [CLI tools](../../README.md#prerequisites) installed
- A Microsoft Teams account for post-deployment connector authorization
- SRE Agent Author or Administrator access to install public marketplace plugins
- Reader access for the agent identity on every subscription assessed for quota,
  capacity, or cross-subscription availability-zone mapping

## Quick Start

Generate an agent configuration:

```bash
./bin/new-agent.sh --recipe cost-management --non-interactive \
  --set agentName=cost-management-sre \
  --set resourceGroup=cost-management-sre \
  --set location=eastus2 \
  --set targetRGs=cost-management-demo \
  -o agents/cost-management/
```

Deploy the generated configuration:

```bash
./bin/deploy.sh agents/cost-management/
```

## Post-deployment setup

Complete the interactive OAuth authorization for Microsoft Teams after every
new deployment.

### Authorize Microsoft Teams

1. Open [Azure SRE Agent](https://sre.azure.com).
2. Select the deployed agent, then go to **Builder** > **Connectors**.
3. Open **Microsoft Teams** and complete the interactive OAuth sign-in.

Teams authorization is intentionally left to the user. The recipe does not
collect, store, or automate user credentials.

### Authorize Azure Resource Manager MCP

Grant the agent's system-assigned managed identity access to the required Cost
Management and billing scopes. The **azure-resource-manager-mcp** connector uses
the ARM MCP endpoint as its data source and requests an `AzureARM` token for
`https://mcp.management.azure.com/.default`. It does not require interactive user
authentication or stored credentials.

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `agentName` | Yes | Lowercase Azure SRE Agent name |
| `resourceGroup` | Yes | Resource group for the agent |
| `location` | Yes | Supported Azure SRE Agent region |
| `targetRGs` | Yes | Comma-separated resource groups to monitor |
| `existingUamiId` | No | Existing user-assigned managed identity resource ID |
| `modelProvider` | No | `Anthropic` or `Azure OpenAI` |
| `existingAgentAppInsightsId` | No | Existing Application Insights resource ID for agent telemetry |

## What You Get

| Category | Items |
|---|---|
| **Agent** | Review-mode Cost Management SRE Agent |
| **Connectors** | Microsoft Teams and Azure Resource Manager HTTP MCP |
| **Tools** | 13 Python tools and 14 selected Cost Management and Pricing MCP tools; five visualization and four Log Query tools are enabled and globally allowed |
| **Skills** | Azure capacity management from its public marketplace and the standalone Azure Cost Management skill |
| **Subagents** | FinOps practitioner, finance, and capacity specialists |
| **Automations** | Scheduled FinOps and capacity operations |
| **Knowledge** | Seven public Azure capacity, quota, reservation, zone-mapping, AKS upgrade, and resilience references |

The Azure Resource Manager MCP connector uses the `x-mcp-toolset: CostManagement`
custom header, `AzureARM` authentication, the
`https://mcp.management.azure.com/.default` token scope, and the agent's
system-assigned managed identity. `create_budget` remains governed by the
agent's **Review** action mode and is not included in the global auto-allow policy.
`tool-overrides.json` controls the portal's On/Off state; `tool-permissions.json`
controls the separate Allow/Ask/Deny approval policy.

## Plugin skills

The recipe registers the public
[`microsoft/azcapman`](https://github.com/microsoft/azcapman) marketplace and
installs `azure-capacity-management` from it. The standalone
`azure-cost-management` skill is included in the recipe from its
[official source](https://github.com/microsoft/finops-toolkit/tree/57dece2be058228c6dca6d2e023ae652b7559fc6/src/templates/agent-skills/azure-cost-management).

## Knowledge sources

The recipe defines seven URL-backed knowledge items in
`data/knowledge-items.json`. Deployment creates them as `KnowledgeWebPage`
items through the SRE Agent data plane, which fetches and indexes each URL.

| Knowledge item | Source |
|---|---|
| `well-architected-capacity-planning` | [Well-Architected capacity planning](https://learn.microsoft.com/azure/well-architected/performance-efficiency/capacity-planning) |
| `well-architected-regions-and-zones` | [Well-Architected regions and availability zones](https://learn.microsoft.com/azure/well-architected/design-guides/regions-availability-zones) |
| `well-architected-disaster-recovery` | [Well-Architected disaster recovery](https://learn.microsoft.com/azure/well-architected/reliability/disaster-recovery) |
| `azure-quotas-overview` | [Azure Quotas overview](https://learn.microsoft.com/azure/quotas/quotas-overview) |
| `azure-capacity-reservations` | [On-demand capacity reservations](https://learn.microsoft.com/azure/virtual-machines/capacity-reservation-overview) |
| `azure-check-zone-peers` | [Check Zone Peers API](https://learn.microsoft.com/rest/api/resources/subscriptions/check-zone-peers?view=rest-resources-2022-12-01) |
| `aks-upgrade-capacity-planning` | [AKS upgrade capacity planning](https://learn.microsoft.com/azure/aks/upgrade-capacity-cost-planning) |

The Microsoft review site is authentication-gated documentation infrastructure,
not an agent connector or identity requirement. The recipe uses only public
Microsoft Learn URLs at runtime.

## Capacity resilience preflight

Run an on-demand preflight before a launch, onboarding wave, new deployment
stamp or region, AKS/VMSS upgrade or replacement, failover topology change,
disaster-recovery drill, large scale event, or allocation-failure retry:

> Ask `azure-capacity-manager` to run a read-only capacity resilience preflight
> for `<workload and scope>`. Return PASS, BLOCK, or INSUFFICIENT EVIDENCE.
> Model complete primary and recovery scale units, normal demand, upgrade or
> replacement surge, failover demand, VM and non-compute quota, subnet IP and
> load-balancer limits, SKU and region access, CRG coverage, fallback
> compatibility, zone mapping where subscriptions differ, evidence freshness,
> runway, owners, and escalation deadlines. Classify any allocation failure
> before recommending action. Do not submit requests or change resources.

Subscription-level evidence requires Reader access at each assessed
subscription. Target-resource-group Reader alone cannot establish
subscription quota or cross-subscription zone mapping. Missing or stale access
evidence must produce `INSUFFICIENT EVIDENCE`, not a guessed mapping.
