# SRE Agent Demo Lab

This lab provides a ready-to-deploy Azure infrastructure for demonstrating SRE Agent troubleshooting capabilities. It includes automated problem scenario generation for realistic demos.

## 🎯 Demo Scenarios

| Scenario | Resource Type | What SRE Agent Detects |
|----------|---------------|------------------------|
| **VM Abnormality Detection** | Virtual Machine | CPU spikes, memory pressure, disk IOPS spikes, low disk space |
| **Backup Failures** | Recovery Services Vault | Failed backup jobs with error details |
| **Service Health Events** | Azure Service Health | Planned maintenance, service outages, health advisories |

## 📋 Prerequisites

- Azure CLI installed and logged in (`az login`)
- PowerShell 7+ or Bash shell
- Azure subscription with sufficient quota (4 vCPUs for Standard_B2s VMs)
- Contributor access to the target subscription

## 🚀 Quick Start

### 1. Deploy Infrastructure

```powershell
# PowerShell
./deploy/deploy.ps1 -SubscriptionId "<your-subscription-id>" -Location "eastus"
```

```bash
# Bash
./deploy/deploy.sh --subscription "<your-subscription-id>" --location "eastus"
```

This creates:
- Resource Group: `infra-sre-demo-rg`
- Log Analytics Workspace: `log-analytics-sre-demo`
- 2 Linux VMs with Azure Monitor Agent: `vm-sre-demo-01`, `vm-sre-demo-02`
- Data Collection Rules for performance metrics
- Recovery Services Vault: `rsv-sre-demo`
- Azure Monitor Alert Rules

### 2. Generate Problem Scenarios

```powershell
# Generate all problem scenarios
./scenarios/generate-problems.ps1
```

Or run individual scenarios:

```powershell
# CPU spike on VM
./scenarios/vm-cpu-spike.ps1 -VMName "vm-sre-demo-01" -DurationMinutes 10

# Memory pressure
./scenarios/vm-memory-pressure.ps1 -VMName "vm-sre-demo-01" -DurationMinutes 10

# Trigger backup failure
./scenarios/backup-failure.ps1 -TriggerFailure

# Resolve backup (for cleanup)
./scenarios/backup-failure.ps1 -ResolveFailure
```

### 3. Verify SRE Agent Access

Use the sample queries in `queries/` folder to verify SRE Agent can detect the issues:

```powershell
# Test VM metrics query
./queries/test-queries.ps1 -Scenario "vm-metrics"

# Test backup status query
./queries/test-queries.ps1 -Scenario "backup-failures"

# Test service health query
./queries/test-queries.ps1 -Scenario "service-health"
```

## 📁 Folder Structure

```
sre-demo-lab/
├── README.md                    # This file
├── deploy/
│   ├── deploy.ps1               # PowerShell deployment script
│   ├── deploy.sh                # Bash deployment script
│   ├── main.bicep               # Main Bicep template
│   ├── modules/
│   │   ├── log-analytics.bicep  # Log Analytics workspace
│   │   ├── virtual-machines.bicep # VMs with AMA
│   │   ├── data-collection.bicep  # DCR for metrics
│   │   ├── recovery-vault.bicep   # RSV and backup policies
│   │   └── alerts.bicep           # Azure Monitor alerts
│   └── parameters.json          # Default parameters
├── scenarios/
│   ├── generate-problems.ps1    # Run all problem scenarios
│   ├── vm-cpu-spike.ps1         # Generate CPU spike
│   ├── vm-memory-pressure.ps1   # Generate memory pressure
│   ├── vm-disk-stress.ps1       # Generate disk I/O and fill disk
│   ├── backup-failure.ps1       # Trigger/resolve backup failure
│   └── scripts/
│       └── stress-test.sh       # Script deployed to VMs
├── queries/
│   ├── test-queries.ps1         # Test all queries
│   ├── kql/
│   │   ├── vm-cpu-spikes.kql    # CPU spike detection
│   │   ├── vm-memory-low.kql    # Memory pressure detection
│   │   ├── vm-disk-iops.kql     # Disk IOPS spike detection
│   │   └── vm-disk-space.kql    # Low disk space detection
│   └── cli/
│       ├── backup-failures.md   # CLI commands for backup status
│       └── service-health.md    # CLI commands for service health
└── cleanup/
    └── cleanup.ps1              # Remove all resources
```

## 🔍 SRE Agent Capabilities Demonstrated

### Azure Monitor (KQL Queries)

The SRE Agent uses Log Analytics queries to detect VM anomalies:

```kql
// Example: Detect CPU spikes > 90% in last 72 hours
Perf
| where TimeGenerated > ago(72h)
| where ObjectName == "Processor" and CounterName == "% Processor Time"
| where CounterValue > 90
| project TimeGenerated, Computer, CounterValue
| order by TimeGenerated desc
```

### Azure CLI

The SRE Agent uses Azure CLI to check backup status and service health:

```bash
# Check backup job failures
az backup job list --resource-group infra-sre-demo-rg \
  --vault-name rsv-sre-demo --status Failed

# Check service health events
az monitor activity-log list --resource-provider "Microsoft.ResourceHealth"
```

### ARM REST APIs

The SRE Agent can also use ARM APIs for advanced scenarios.

## ⏱️ Timeline for Demo

| Time | Action |
|------|--------|
| T-60 min | Deploy infrastructure |
| T-30 min | Run stress scenarios to generate metrics |
| T-10 min | Trigger backup failure |
| T-0 | Demo: SRE Agent detects and troubleshoots issues |

## 🧹 Cleanup

```powershell
./cleanup/cleanup.ps1 -SubscriptionId "<your-subscription-id>"
```

This removes all resources in the `infra-sre-demo-rg` resource group.

## 💰 Cost Estimate

| Resource | SKU | Estimated Cost (per hour) |
|----------|-----|---------------------------|
| 2x Linux VMs | Standard_B2s | ~$0.08 |
| Log Analytics | Pay-as-you-go | ~$0.01 (minimal data) |
| Recovery Services Vault | Standard | ~$0.02 |
| **Total** | | **~$0.11/hour** |

**Recommendation**: Deploy, run demo, cleanup within 2-3 hours to minimize costs.

## 🐛 Troubleshooting

### VMs not showing metrics
- Verify Azure Monitor Agent is installed: `az vm extension list --resource-group infra-sre-demo-rg --vm-name vm-sre-demo-01`
- Check DCR association: `az monitor data-collection rule association list --resource <vm-resource-id>`

### Backup not failing
- Ensure NSG rule is blocking AzureBackup service tag
- Wait for next backup window (configured for every 30 minutes)

### No Service Health events
- Service Health events are real Azure incidents; use historical events in Activity Log for demo
- Create a Service Health alert to show configuration

## 📚 Related Documentation

- [Azure Monitor Agent Overview](https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-overview)
- [Recovery Services Vault Overview](https://learn.microsoft.com/en-us/azure/backup/backup-azure-recovery-services-vault-overview)
- [Azure Service Health](https://learn.microsoft.com/en-us/azure/service-health/service-notifications)
- [KQL Query Language](https://learn.microsoft.com/en-us/azure/data-explorer/kusto/query/)
