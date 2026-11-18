# Cost management

Deploy an Azure SRE Agent for Azure Cost Management analytics and FinOps operations.

## Use cases

- Compare spend by service and review reservation or savings plan recommendations.
- Investigate unexpected charges by identifying top cost drivers and checking anomaly alert coverage.
- Review billed AI workload costs alongside GPU quota and regional SKU availability.
  Quota and SKU availability don't measure GPU utilization or guarantee deployment
  capacity. Billing data isn't per-request telemetry.

## Prerequisites

- An Azure subscription and permission to assign roles at each target scope
- At least one Azure resource group to monitor
- All [CLI tools](../../README.md#prerequisites) installed
- SRE Agent Author or Administrator access to install public marketplace plugins
- A Microsoft 365 account that's a member of the target Teams team and channel
- A billing administrator who can grant billing-scope access when needed

## Quick start

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

Complete both steps after deployment. The deployment's target resource group
assignments don't replace the subscription and billing permissions described
below.

### Step 1: Authorize Microsoft Teams and configure the channel

This step is required for Teams delivery. `deploy.sh` and
`Deploy-Agent.ps1` provision the `cost-management-teams` connection and bind
the seven ConnectorV2 operations, but they don't sign in to Microsoft 365.
An interactive OAuth sign-in is required to change the connection status from
**Unauthenticated** to **Connected**.

1. Open the [Azure SRE Agent portal](https://sre.azure.com) and select your
   deployed agent.
2. Go to **Build + setup** > **Extensions** > **Connectors**.
3. Select the `cost-management-teams` (`microsoft-teams`) connector, select
   **Sign in** or **Authorize**, and complete the Microsoft 365 sign-in with
   an account that's a member of the target Teams team and channel.
4. Confirm that the connector status is **Connected**.
5. Under **Subagent builder** > **MCP connectors**, verify that
   `cost-management-teams` is bound with all seven operations:
   `GetUnifiedActionSchema`, `PostMessageToConversation`,
   `PostCardToConversation`, `ReplyWithMessageToConversation`,
   `ReplyWithCardToConversation`, `UpdateCardInConversation`, and
   `GetMessagesFromChannel`.
6. Open a chat with the agent and tell it which team and channel to use for
   recurring digests and anomaly escalations. For example:

   > Use Microsoft Teams channel `<channel-name>` (`teamId: <team-id>`,
   > `channelId: <channel-id>`) as our default FinOps reporting channel and
   > remember it in memory.

The [custom instructions](custom-instructions.md) tell the agent to ask for a
channel and remember it if none is configured. The recipe doesn't collect or
automate user credentials. If the connector is missing, check the deployment
output: data-plane resources are skipped when a data-plane token isn't
available.

### Step 2: Assign Azure and billing roles to both identities

The agent has two distinct managed identities. Assign permissions to the
identity that performs each operation, on every applicable target scope. A
resource group assignment doesn't provide subscription-wide quota or
cross-subscription zone-mapping access.

| Identity | Used for | Required access |
|---|---|---|
| System-assigned managed identity (SMID) | The `azure-resource-manager-mcp` connector at `https://mcp.management.azure.com`, with `x-mcp-toolset: CostManagement` and an `AzureARM` token for `https://mcp.management.azure.com/.default` | **Reader** and **Cost Management Reader** on target subscriptions for read-only cost, forecast, budget, alert, and retail-price queries. Billing-scope queries require the separate billing role described below. Optional MCP `create_budget` requires **Cost Management Contributor** on the target scope. |
| User-assigned managed identity (UAMI) | The agent's Python tools, including `resource-graph-query`, `vm-quota-usage`, `sku-availability`, `benefit-recommendations`, `db-service-quotas`, `non-compute-quotas`, `capacity-reservation-groups`, `zone-mapping`, and the budget, alert, and Advisor write tools | **Reader** and **Cost Management Reader** on target subscriptions for read-only inventory, quota, SKU, and subscription-scoped benefit queries. Billing-account queries from `benefit-recommendations` also require a billing reader role. Optional write tools need the permissions described below. |

The deployment creates an identity named `<agent-name>-id-*` unless you
provide `existingUamiId`. The Python tools use `DefaultAzureCredential` rather
than explicitly selecting an identity. Verify that the runtime resolves it to
the intended UAMI; if it uses another principal, grant the required access to
that principal instead. The MCP connector explicitly uses the SMID.

#### Assign subscription roles

Sign in to Azure CLI before running these commands. Your account needs
permission to create role assignments at the target scope. First, replace the
placeholders with the subscription containing the agent, its resource group and
name, and the subscription to assess. Then list the identities attached to the
agent:

```bash
AGENT_SUBSCRIPTION_ID="<agent-subscription-id>"
AGENT_RESOURCE_GROUP="<agent-resource-group>"
AGENT_NAME="<agent-name>"
TARGET_SUBSCRIPTION_ID="<target-subscription-id>"
AGENT_ID="/subscriptions/$AGENT_SUBSCRIPTION_ID/resourceGroups/$AGENT_RESOURCE_GROUP/providers/Microsoft.App/agents/$AGENT_NAME"
TARGET_SCOPE="/subscriptions/$TARGET_SUBSCRIPTION_ID"

az resource show --ids "$AGENT_ID" --api-version 2025-05-01-preview \
  --query identity.userAssignedIdentities -o json
```

Identify the user-assigned identity used by the Python runtime. If several
identities are attached, don't assume the first one is correct. Replace
`<user-assigned-identity-resource-id>` with its resource ID before running
the role assignments:

```bash
UAMI_ID="<user-assigned-identity-resource-id>"
SMID_PRINCIPAL_ID=$(az resource show --ids "$AGENT_ID" \
  --api-version 2025-05-01-preview --query identity.principalId -o tsv)
UAMI_PRINCIPAL_ID=$(az identity show --ids "$UAMI_ID" --query principalId -o tsv)

az role assignment create --assignee-object-id "$SMID_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal --role "Reader" --scope "$TARGET_SCOPE"
az role assignment create --assignee-object-id "$SMID_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal --role "Cost Management Reader" --scope "$TARGET_SCOPE"
az role assignment create --assignee-object-id "$UAMI_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal --role "Reader" --scope "$TARGET_SCOPE"
az role assignment create --assignee-object-id "$UAMI_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal --role "Cost Management Reader" --scope "$TARGET_SCOPE"
```

Repeat the assignments for each target subscription.

#### Grant billing-scope access when needed

Subscription roles don't grant billing permissions. For MCP
`list_benefit_utilization`, `list_reservation_transactions`, and shared
`get_benefit_recommendations`, grant the SMID access at the applicable billing
scope. Grant equivalent access to the Python runtime identity if you call
`benefit-recommendations` at billing-account scope:

- **Enterprise Agreement (EA):** Grant `EnrollmentReader` on
  `/providers/Microsoft.Billing/billingAccounts/<enrollment-id>`.
- **Microsoft Customer Agreement (MCA):** Grant the appropriate Billing
  Account Reader, Billing Profile Reader, or Invoice Section Reader role at
  the scope queried.

Billing roles are separate from Azure RBAC subscription roles. Have a billing
administrator follow [Assign EA roles to service principals](https://learn.microsoft.com/azure/cost-management-billing/manage/assign-roles-azure-service-principals)
or [Manage MCA billing roles](https://learn.microsoft.com/azure/cost-management-billing/manage/understand-mca-roles).
Don't use the subscription `az role assignment create` examples for billing
role assignments.

#### Grant optional write permissions

Grant write access only for workflows you intend to use. For MCP
`create_budget`, grant the SMID **Cost Management Contributor**. For Python
`deploy-budget`, `deploy-bulk-budgets`, `deploy-anomaly-alert`, and
`deploy-bulk-anomaly-alerts`, grant the UAMI **Cost Management Contributor**.
For `suppress-advisor-recommendations`, grant the UAMI **Contributor** at the
applicable target scopes, or use a custom role with the necessary Advisor
suppression permissions. **Advisor Reviews Contributor** alone doesn't
provide suppression write access. See [Advisor roles and permissions](https://learn.microsoft.com/azure/advisor/permissions).
The tool queries subscriptions under a management group, so grant access
across the subscriptions it must assess.

For example, after setting the variables above:

```bash
# Optional: MCP budget creation
az role assignment create --assignee-object-id "$SMID_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal --role "Cost Management Contributor" --scope "$TARGET_SCOPE"

# Optional: Python budget and anomaly alert tools
az role assignment create --assignee-object-id "$UAMI_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal --role "Cost Management Contributor" --scope "$TARGET_SCOPE"

# Optional: Python Advisor suppression
az role assignment create --assignee-object-id "$UAMI_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal --role "Contributor" --scope "$TARGET_SCOPE"
```

The agent uses **Review** action mode for interactive work. Granting a role
doesn't replace the agent's approval policy. Scheduled tasks run in autonomous
mode, where tools set to **Ask** execute without human approval. Review the
enabled tools and permissions before you enable a scheduled task. See
[Run modes](https://learn.microsoft.com/azure/sre-agent/run-modes).

## Try a read-only cost review

After you [assign subscription roles](#assign-subscription-roles), open an agent
chat and replace `<subscription-id>` with one authorized subscription:

> For subscription `<subscription-id>`, compare spend by service for the last
> 30 days against the preceding 30 days. List the largest increases and cite
> the sources. Flag missing evidence. Make no changes.

For recurring reviews, see [scheduled tasks](#scheduled-tasks).

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

## What you get

| Category | Items |
|---|---|
| Agent | Review-mode Cost Management SRE Agent |
| MCP connector | `azure-resource-manager-mcp`: 14 selected tools, including five default tools and nine added by `x-mcp-toolset: CostManagement` |
| Managed ConnectorV2 | `cost-management-teams` (`microsoft-teams`): seven operations |
| Skill | `azure-cost-management`, with 12 reference guides |
| Subagents | `finops-practitioner`, `azure-capacity-manager`, and `chief-financial-officer` |
| Custom tools | 13 Python `ExtendedAgentTool` tools |
| Scheduled tasks | 17 FinOps and capacity tasks, listed below |
| Marketplace plugin | `microsoft/azcapman`, which installs the `azure-capacity-management` skill |
| Knowledge | Seven URL-backed knowledge sources; the indexed document count can vary |
| Common prompt | `safety-rules` |
| Custom instructions | FinOps [custom-instructions.md](custom-instructions.md) |
| Built-in tools | Five visualization and four Log Query tools enabled and globally allowed |

The Azure Resource Manager MCP connector uses the `x-mcp-toolset: CostManagement`
custom header, `AzureARM` authentication, the
`https://mcp.management.azure.com/.default` token scope, and the agent's
system-assigned managed identity. `create_budget` remains governed by the
agent's **Review** action mode and is not included in the global auto-allow policy.
`tool-overrides.json` controls the portal's On/Off state; `tool-permissions.json`
controls the separate Allow/Ask/Deny approval policy.

### Custom Python tools

The recipe deploys these 13 `ExtendedAgentTool` tools:

- `benefit-recommendations`
- `capacity-reservation-groups`
- `db-service-quotas`
- `deploy-anomaly-alert`
- `deploy-budget`
- `deploy-bulk-anomaly-alerts`
- `deploy-bulk-budgets`
- `non-compute-quotas`
- `resource-graph-query`
- `sku-availability`
- `suppress-advisor-recommendations`
- `vm-quota-usage`
- `zone-mapping`

### Scheduled tasks

The schedules below are the cron expressions in the recipe. Check the
agent's scheduler time zone before interpreting the times.

| Task | Cadence (cron) | Description |
|---|---|---|
| `AdvisorSuppressionReview` | Monthly, `0 9 1 * *` | Review active Advisor suppressions for stale or expired decisions. |
| `AIWorkloadCostAnalysis` | Monthly, `0 10 1 * *` | Analyze Azure OpenAI token economics, model efficiency, and cost allocation. |
| `AlertCoverageAudit` | Monthly, `0 8 16 * *` | Audit cost anomaly alert coverage across active subscriptions. |
| `BenefitRecommendationReview` | Weekly, `0 8 * * 5` | Review reservation and savings plan recommendations. |
| `BudgetCoverageAudit` | Monthly, `0 8 15 * *` | Audit subscription budget coverage and missing controls. |
| `CapacityDailyMonitor` | Daily, `30 6 * * *` | Check quota usage, capacity reservation group utilization, and zone capacity. |
| `CapacityMonthlyPlanning` | Monthly, `0 9 1 * *` | Review demand forecasts, capacity requests, and governance. |
| `CapacityQuarterlyStrategy` | Quarterly, `0 9 1 1,4,7,10 *` | Review FinOps maturity, commitment alignment, and architecture evolution. |
| `CapacityWeeklySupplyReview` | Weekly, `0 8 * * 1` | Review quota headroom, capacity reservation group costs, SKU availability, and benefit recommendations. |
| `ComputeUtilizationTrend` | Weekly, `0 7 * * 1` | Review VM quota utilization trends across subscriptions and regions. |
| `CostOptimization` | Weekly, `0 8 * * 1` | Report on orphaned resources, rightsizing, and commitments. |
| `DbQuotaAudit` | Weekly, `0 7 * * 3` | Audit database quota and region or availability-zone access risks. |
| `Monthly` | Monthly, `15 17 5 * *` | Analyze month-over-month costs. |
| `NonComputeQuotaAudit` | Weekly, `0 7 * * 2` | Audit storage, network, and other non-compute quota risks. |
| `Semiannual` | Twice yearly, `0 9 5 1,7 *` | Analyze year-over-year financial results for January and July close checkpoints. |
| `SkuAvailabilityAudit` | Weekly, `30 7 * * 3` | Audit regional SKU availability and deployment restrictions. |
| `StoragePaasGrowthForecast` | Monthly, `0 8 1 * *` | Forecast storage and platform-as-a-service quota growth. |

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
