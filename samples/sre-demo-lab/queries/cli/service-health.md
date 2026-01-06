# Azure Service Health Detection - CLI Commands

This document provides Azure CLI commands for detecting and monitoring 
Azure Service Health events using the SRE Agent.

## Overview

Azure Service Health provides three types of health events:
1. **Service Issues** - Azure service problems affecting your resources
2. **Planned Maintenance** - Upcoming maintenance that might affect availability
3. **Health Advisories** - Changes requiring action (deprecated features, quota limits)

## List Service Health Events

### All Service Health Events

```bash
# Query activity log for Service Health events (last 7 days)
az monitor activity-log list \
  --start-time $(date -d '7 days ago' --utc +%Y-%m-%dT%H:%M:%SZ) \
  --query "[?category.value=='ServiceHealth']" \
  --output json
```

### PowerShell Version

```powershell
# Query activity log for Service Health events (last 7 days)
$startTime = (Get-Date).AddDays(-7).ToString("yyyy-MM-ddTHH:mm:ssZ")
az monitor activity-log list `
  --start-time $startTime `
  --query "[?category.value=='ServiceHealth']" `
  --output json
```

## Filter by Event Type

### Service Issues (Outages)

```bash
# Get service issues/outages
az monitor activity-log list \
  --start-time $(date -d '30 days ago' --utc +%Y-%m-%dT%H:%M:%SZ) \
  --query "[?category.value=='ServiceHealth' && properties.incidentType=='Incident'].{Title:properties.title, Status:properties.stage, ImpactedService:properties.service, ImpactedRegion:properties.region, StartTime:eventTimestamp}" \
  --output table
```

### Planned Maintenance

```bash
# Get planned maintenance events
az monitor activity-log list \
  --start-time $(date -d '30 days ago' --utc +%Y-%m-%dT%H:%M:%SZ) \
  --query "[?category.value=='ServiceHealth' && properties.incidentType=='Maintenance'].{Title:properties.title, Status:properties.stage, ImpactedService:properties.service, MaintenanceWindow:properties.maintenanceWindow, StartTime:eventTimestamp}" \
  --output table
```

### Health Advisories

```bash
# Get health advisories
az monitor activity-log list \
  --start-time $(date -d '30 days ago' --utc +%Y-%m-%dT%H:%M:%SZ) \
  --query "[?category.value=='ServiceHealth' && properties.incidentType=='Informational'].{Title:properties.title, Description:properties.communication, StartTime:eventTimestamp}" \
  --output table
```

### Security Advisories

```bash
# Get security advisories
az monitor activity-log list \
  --start-time $(date -d '30 days ago' --utc +%Y-%m-%dT%H:%M:%SZ) \
  --query "[?category.value=='ServiceHealth' && properties.incidentType=='ActionRequired'].{Title:properties.title, Severity:properties.severity, StartTime:eventTimestamp}" \
  --output table
```

## Filter by Region

```bash
# Get events for a specific region (e.g., eastus)
az monitor activity-log list \
  --start-time $(date -d '30 days ago' --utc +%Y-%m-%dT%H:%M:%SZ) \
  --query "[?category.value=='ServiceHealth' && contains(properties.impactedServices, 'East US')].{Title:properties.title, Type:properties.incidentType, Status:properties.stage}" \
  --output table
```

## Filter by Service

```bash
# Get events for a specific service (e.g., Virtual Machines)
az monitor activity-log list \
  --start-time $(date -d '30 days ago' --utc +%Y-%m-%dT%H:%M:%SZ) \
  --query "[?category.value=='ServiceHealth' && contains(properties.service, 'Virtual Machines')].{Title:properties.title, Type:properties.incidentType, Status:properties.stage, StartTime:eventTimestamp}" \
  --output table
```

## Check Current Active Issues

```bash
# Get currently active service issues (status: Active)
az monitor activity-log list \
  --start-time $(date -d '7 days ago' --utc +%Y-%m-%dT%H:%M:%SZ) \
  --query "[?category.value=='ServiceHealth' && properties.stage=='Active'].{Title:properties.title, Service:properties.service, Region:properties.region, StartTime:eventTimestamp, TrackingId:properties.trackingId}" \
  --output table
```

## Get Detailed Event Information

```bash
# Get full details of a specific event by correlation ID
CORRELATION_ID="<correlation-id-from-list>"

az monitor activity-log list \
  --start-time $(date -d '30 days ago' --utc +%Y-%m-%dT%H:%M:%SZ) \
  --query "[?correlationId=='$CORRELATION_ID']" \
  --output json
```

## Service Health Alert Configuration

### List Existing Service Health Alerts

```bash
# List all activity log alerts (includes service health alerts)
RESOURCE_GROUP="infra-sre-demo-rg"

az monitor activity-log alert list \
  --resource-group $RESOURCE_GROUP \
  --output table
```

### Check Alert Configuration

```bash
# Get details of a service health alert
ALERT_NAME="alert-sre-demo-service-health"

az monitor activity-log alert show \
  --resource-group $RESOURCE_GROUP \
  --name $ALERT_NAME \
  --output json
```

## ARM REST API for Service Health

```bash
# Query Service Health events via REST API
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# Get events from the last 7 days
START_TIME=$(date -d '7 days ago' --utc +%Y-%m-%dT%H:%M:%SZ)

az rest --method get \
  --uri "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.ResourceHealth/events?api-version=2022-10-01&\$filter=eventTime ge $START_TIME" \
  --output json
```

## Resource Health (Individual Resource Status)

```bash
# Check health of a specific VM
RESOURCE_GROUP="infra-sre-demo-rg"
VM_NAME="vm-sre-demo-01"

# Get current availability status
az resource show \
  --resource-group $RESOURCE_GROUP \
  --name $VM_NAME \
  --resource-type "Microsoft.Compute/virtualMachines" \
  --query "properties.instanceView.statuses[?starts_with(code, 'PowerState')].displayStatus" \
  --output tsv
```

## Integration with Azure Monitor

### Query Activity Log via Log Analytics

If Activity Log is routed to Log Analytics, use this KQL query:

```kql
AzureActivity
| where CategoryValue == "ServiceHealth"
| where TimeGenerated > ago(7d)
| project 
    TimeGenerated,
    Title = Properties.title,
    IncidentType = Properties.incidentType,
    Status = Properties.stage,
    Service = Properties.service,
    Region = Properties.region,
    TrackingId = Properties.trackingId
| order by TimeGenerated desc
```

## Event Types Reference

| Incident Type | Description | Urgency |
|--------------|-------------|---------|
| Incident | Service outage or degradation | High |
| Maintenance | Planned maintenance window | Medium |
| Informational | Health advisories, deprecations | Low |
| ActionRequired | Security issues requiring action | High |

## Status Values Reference

| Status | Description |
|--------|-------------|
| Active | Issue is currently occurring |
| Investigating | Microsoft is investigating |
| Mitigated | Issue has been partially resolved |
| Resolved | Issue is fully resolved |
| RCA Available | Root Cause Analysis published |
