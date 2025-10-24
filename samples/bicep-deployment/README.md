# SRE Agent Bicep Deployment

This Bicep deployment allows you to deploy an SRE Agent with configurable subscription, resource group targeting, and role assignments across multiple resource groups.

## New Features

1. **Subscription Targeting**: Specify the subscription where the SRE Agent should be deployed
2. **Custom Resource Group**: Deploy the SRE Agent to any resource group 
3. **Multi-Resource Group Access**: Grant the SRE Agent permissions across multiple resource groups
4. **Cross-Subscription Support**: Target resource groups across different subscriptions

## Files Structure

- `minimal-sre-agent.bicep` - Main template (subscription-scoped)
- `sre-agent-resources.bicep` - Resource group-scoped module containing all resources
- `role-assignments-minimal.bicep` - Role assignments for the deployment resource group
- `role-assignments-target.bicep` - Role assignments for target resource groups
- `minimal-sre-agent.parameters.json` - Example parameters file
- `deploy.sh` - Interactive deployment script with command-line interface

## Parameters

### Required Parameters
- `agentName`: Name of the SRE Agent
- `deploymentResourceGroupName`: Resource group where SRE Agent will be deployed

### Optional Parameters
- `subscriptionId`: Target subscription (defaults to current subscription)
- `location`: Azure region (default: eastus2)
- `existingManagedIdentityId`: Use existing managed identity instead of creating new one
- `accessLevel`: High or Low access level (default: High)
- `agentMode`: Review, Autonomous, or ReadOnly (default: Review)
- `targetResourceGroups`: Array of resource group names to grant access to
- `targetSubscriptions`: Array of subscription IDs for target resource groups

## Deployment Methods

### Quick Start: Deploy Without Target Resource Groups

If you want to deploy just the SRE Agent infrastructure without assigning it to any target resource groups:

```bash
# Interactive mode - leave target RGs empty
./deploy.sh

# Or use the no-targets config file
./deploy.sh --config sre-agent-no-targets.config

# Or command line mode
./deploy.sh --no-interactive \
  -s "your-subscription-id" \
  -r "rg-sre-agent" \
  -n "my-sre-agent" \
  --yes
```

See [DEPLOY-NO-TARGETS.md](DEPLOY-NO-TARGETS.md) for complete details on standalone deployment.

### Method 1: Using Azure CLI with Parameters File

1. Update `minimal-sre-agent.parameters.json` with your values:
```json
{
  "parameters": {
    "agentName": { "value": "my-sre-agent" },
    "subscriptionId": { "value": "12345678-1234-1234-1234-123456789012" },
    "deploymentResourceGroupName": { "value": "rg-sre-agent" },
    "targetResourceGroups": { 
      "value": ["rg-production-web", "rg-production-data"] 
    }
  }
}
```

2. Deploy:
```bash
az deployment sub create \
  --subscription "12345678-1234-1234-1234-123456789012" \
  --location "eastus2" \
  --template-file minimal-sre-agent.bicep \
  --parameters @minimal-sre-agent.parameters.json
```

### Method 2: Using the Deployment Script

Make the script executable and run:
```bash
chmod +x deploy.sh
./deploy.sh -s "12345678-1234-1234-1234-123456789012" \
           -r "rg-sre-agent" \
           -n "my-sre-agent" \
           -l "eastus2" \
           -a "High" \
           -m "Review" \
           -t "rg-prod-web,rg-prod-data,rg-staging"
```

### Method 3: Direct Azure CLI with Inline Parameters

```bash
az deployment sub create \
  --subscription "12345678-1234-1234-1234-123456789012" \
  --location "eastus2" \
  --template-file minimal-sre-agent.bicep \
  --parameters \
    agentName="my-sre-agent" \
    subscriptionId="12345678-1234-1234-1234-123456789012" \
    deploymentResourceGroupName="rg-sre-agent" \
    location="eastus2" \
    accessLevel="High" \
    agentMode="Review" \
    targetResourceGroups='["rg-prod-web","rg-prod-data"]'
```

## Access Levels

### Low Access Level
- Log Analytics Reader
- Reader

### High Access Level  
- Log Analytics Reader
- Reader
- Contributor

## Cross-Subscription Targeting

To target resource groups in different subscriptions, provide both `targetResourceGroups` and `targetSubscriptions` arrays:

```json
{
  "targetResourceGroups": {
    "value": ["rg-prod-web", "rg-prod-data", "rg-staging"]
  },
  "targetSubscriptions": {
    "value": [
      "12345678-1234-1234-1234-123456789012",
      "12345678-1234-1234-1234-123456789012", 
      "87654321-4321-4321-4321-210987654321"
    ]
  }
}
```

The arrays are matched by index - the first resource group uses the first subscription, etc.

## Outputs

The template provides these outputs:
- `agentName`: Name of the created SRE Agent
- `agentId`: Resource ID of the SRE Agent
- `agentPortalUrl`: Direct link to manage the agent in Azure Portal
- `userAssignedIdentityId`: Resource ID of the managed identity
- `applicationInsightsConnectionString`: Connection string for Application Insights
- `logAnalyticsWorkspaceId`: Resource ID of the Log Analytics workspace
- `createdNewManagedIdentity`: Boolean indicating if a new managed identity was created

## Prerequisites

- Azure CLI installed and authenticated
- Appropriate permissions to create resources and assign roles
- Owner or User Access Administrator role on target subscriptions/resource groups
- SRE Agent resource provider registered in target subscriptions

## Troubleshooting

### Permission Issues
Ensure you have:
- Owner or Contributor + User Access Administrator roles
- Permission to create role assignments across target resource groups
- Permission to create resources in the deployment resource group

### Cross-Subscription Scenarios
- Ensure you have permissions in all target subscriptions
- Verify resource group names exist in their respective subscriptions
- Check that the SRE Agent resource provider is available in target regions
