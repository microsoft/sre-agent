# Automating end to end Incident diagnosis, mitigation, root cause analysis using Azure SRE Agent

This document provides step-by-step instructions for reproducing an SRE incident scenario with the Octopets application on Azure.

## Prerequisites

- Azure subscription access
- PagerDuty account setup
- Git access to personal repository

## Setup Steps

### Step 1: Deploy Octopets Application
- Get Octopets app from Azure samples https://github.com/Azure-Samples/octopets
- Clone the repository
- Before deploying it, just run "azd infra generate" to get bicep files
- Follow the instructions in the repository to deploy it (you need dotnet9 and docker running)
- Deploy to your Azure subscription
- Verify the application is working as expected
- Upload the code to your personal repository

### Step 2: Configure Application Settings
Make sure these settings are on the frontend app and backend container apps
- Application deploys with  `REACT_APP_USE_MOCK_DATA` to `false` on the frontend app (containerapp octopetsfe)
- Set `Errors` to `true` on the backend app (will turn on code that consumes memory), octopetsapi

### Step 3: Create SRE Agent 
Create SRE Agent using Azure Portal, search for SRE Agent and create a new agent with Resource group as the resource group for octopets, select the same resource group to be managed by SRE Agent, region as East-US-2

### Step 4: Connect SRE Agent to GitHub repo that has app's source code
- Go to Resource mapping tab of SREA
- for octopetsapi, on right side, there is a score card which shows "connect repository"
- click on "connect repository", supply GitHub repo URL 
- Authorize link shows up now and click to authorize 
- Now agent knows octopetsapi is connected to GitHub repo URL

### Step 5: connect SRE Agent to PagerDuty Configuration
Inside SRE Agent -
Go to Incident Management tab, under Incident management platform, connect to Pager Duty with credentials above. 
**PagerDuty Details:**
- **API Key:** your API key
- **Email:** `your email`
- **PagerDuty:** https://<xxx>.pagerduty.com/
 
### Step 6: Supply your incident handling runbook instructions to SRE Agent
1. Under Incident Management tab in SRE Agent, go to incident response plans and delete default quick start handler and create new one. 
2. Select "all" for all options, choose review or autonomous per your demo. 
3. Check "add" guidance and supply these instructions in text box below "Instruction generation guidance"

   Copy the prompt from [custom-instructions/octopetshandler.txt](custom-instructions/octopetshandler.txt)

4. click "generate", once instructions are generated, copy/paste the runbook instructions below. Make sure to subscription id, replace app name, resource group name and github link are correct ones
5. Once instructions are generated, in custom instructions box, paste the instructions from this SREA-octopets-custominstructions.md file
6. Make sure the tool list has these tools
   1. AcknowledgePagerDutyIncident
   2. AddNoteToPagerDutyIncident
   3. CreateGithubIssue
   4. FindConnectedGitHubRepo
   5. GetCurrentUtcTime
   6. GetIaCForGitHub
   7. GetMetricTimeSeriesElementsForAzureResource
   8. GetPagerDutyIncidentById
   9. GetPagerDutyIncidents
   10. ListAvailableMetrics
   11. PlotAreaChartWithCorrelation
   12. ResolvePagerDutyIncident
   13. RunAzCliReadCommands
   14. RunAzCliWriteCommands
   15. QuerySourceBySemanticSearch

7. **save incident response plan**

### Step 7: Inject Memory Leak
- Go to Octopets front end app end point. Trigger memory leak by clicking "browse listings/view details" 5 times

### Step 8: Send Incident via PagerDuty

**Incident Details:**
- **Title:** octopetsapi container app is throwing 500 errors, view details is not responding
- **Description:** octopetsapi container app is throwing 500 errors, view details is slow to respond
                   - Subscription ID:** your sub ID
                   - Resource Group:** `your resource group
- **Severity:** P1
- **Service:** Any service


