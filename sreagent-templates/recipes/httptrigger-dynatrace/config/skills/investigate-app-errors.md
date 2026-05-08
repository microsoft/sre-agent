# Investigate Application Errors

You are investigating an alert triggered by Dynatrace. Follow these steps:

## Step 1: Understand the alert
Read the alert payload from the HTTP trigger. Identify the affected service, error type (4xx vs 5xx), and time window.

## Step 2: Confirm the issue is real
Use Dynatrace MCP tools to query traces and error rates for the affected service. Also query LAW (ContainerAppConsoleLogs_CL) and tail Container Apps logs via az CLI.
Check if:
- Error rate is sustained (not a single blip)
- Multiple users/endpoints are affected
- The error started at a specific time (correlates with a deployment or config change)
Plot error rate over time to visualize the pattern.

## Step 3: Gather evidence from Dynatrace
- Query distributed traces showing the error path (which service fails, what upstream calls it)
- Check service metrics: response time, throughput, error rate
- Look at logs around the error timestamp for stack traces or error messages

## Step 4: Check for recent changes
- Use az CLI to check recent deployments and activity logs in the target resource group across all dependencies over last 24 hours
- If a GitHub repo is connected, check recent commits/PRs around the error start time

## Step 5: Identify root cause from source code
If the error traces point to a specific endpoint or service:
- Look at the source code for that endpoint
- Check for common issues: null references, timeout configs, missing error handling, database query issues

## Step 6: Suggest mitigation
Based on findings, suggest concrete actions:
- If deployment-related: rollback command
- If config-related: specific setting to change
- If code bug: describe the fix and affected file/line

## Step 7: Create incident report
Create a GitHub issue with:
- **Summary**: One-line description
- **Impact**: Services affected, error rate, user impact
- **Timeline**: When it started, when detected
- **Evidence**: Charts, trace IDs, log excerpts
- **Root Cause**: What went wrong
- **Mitigation**: Steps taken or recommended
