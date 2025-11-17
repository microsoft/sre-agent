# Automate Incidents Using SRE Agent

This guide walks you through setting up end-to-end incident automation for Azure resource errors using Incident Management platform and Azure SRE Agent.

## Prerequisites

- **Azure SRE Agent** deployed in Azure with the Octopets application connected
  - [Create and deploy Azure SRE Agent](https://learn.microsoft.com/en-us/azure/sre-agent/usage)
  - Complete the [Octopets Setup Guide](./sample-apps/octopets-setup.md) to deploy the sample application
- **Azure subscription** with the Octopets application deployed
- **PagerDuty account** with API key
- **GitHub account** with repository access
- **Outlook/Microsoft 365** account for notifications

Once you've completed this setup, proceed to the [Octopets Memory Leak sample](./01-octopets-memleak-sample.md) for a complete end-to-end demonstration.

## What You'll Build

An automated incident response system that:
- Receives 500 error incidents from PagerDuty
- Diagnoses Azure resource issues using metrics and logs
- Performs automated mitigation (scaling, restarts, configuration fixes)
- Sends updates to Outlook 
- Creates GitHub issues with root cause analysis and code fixes

## Step 1: Connect Agent to Incident Management platform

For detailed instructions, see [Connect to incident management platforms](https://learn.microsoft.com/en-us/azure/sre-agent/incident-management?tabs=pagerduty).


## Step 2: Set Up Agent to Outlook Connector

1. In your SRE Agent, go to **Settings**
2. Select **Connectors**
3. Click **Add Connector** or select **Outlook**

![Setting up Email - Step 1](./images/settingupemail-step1.png)

4. **Login to Outlook** with your email address
5. Select **System Assigned Managed Identity** for authentication
6. Give your Outlook connector a name (e.g., "SRE Agent Notifications")
7. Click **Save**

![Setting up Email - Step 2](./images/settingupemail-step2.png)


## Step 3: Connect Agent to GitHub Repository

1. In your SRE Agent, go to **Resource Mapping** tab
2. Find your Azure resources in the list (e.g., Container Apps, App Services)
3. For each resource generating 500 errors:
   - Click **Connect Repository** on the right side
   - Enter your GitHub repository URL (e.g., `https://github.com/yourorg/yourapp`)
   - Click **Authorize** to grant access
4. Verify the connection shows as "Connected"

![Resource Mapping](./images/resourcemapping.png)

## Step 4: Create SRE Agent Subagent for Azure Errors

1. In your SRE Agent, go to **Subagent Builder**
2. Click **Create Subagent**
   - **Name**: Enter **PDazureresourceerrorhandler**
   - **Instructions**: "Handles Azure resource errors from incident management platform"
   - **Handoff Instructions**: "Activate for incidents with 500 errors or Azure resource failures"
3. Click **Save**

![Subagent Create](./images/subagentcreate.png)

## Step 5: Set Up Incident Trigger

1. Go to **Subagent Builder**
2. Click **Create Incident Trigger**

![Incident Trigger - Step 1](./images/incidenttrigger-step1.png)

3. Supply the trigger details:
   - **Name**: Enter a descriptive name (e.g., "Azure 500 Error Trigger")
   - **Filters**: Configure which incidents should be handled by the agent:
     - **Incident Type**: Select relevant types
     - **Priority**: Select All or relevant options
     - **Impacted Service**: Select services related to your Azure resources
4. Choose processing mode:
   - **Review**: Agent suggests actions and waits for approval
   - **Autonomous**: Agent executes actions automatically
5. Click **Create**

![Incident Trigger - Step 2](./images/incidenttrigger-step2.png)

## Next Steps

Now that you've configured the basic connections, you're ready to create subagents and test incident automation.

For a complete end-to-end example with subagent configuration and testing, see the [Octopets Memory Leak Sample](./octopets-memleak-pagerduty.md).

## Example Subagent Configuration

See [pd-azure-resource-error-handler.yaml](./subagents/pd-azure-resource-error-handler.yaml) for a complete subagent configuration example that handles Azure resource errors.

## Support

For issues or questions, please open a GitHub issue in this repository.
