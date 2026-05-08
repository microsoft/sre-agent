# Investigate VM Performance Issues

Diagnose virtual machine performance problems using Azure Monitor metrics, Log Analytics, and Azure CLI.

## Step 1: Identify Target VMs

List VMs in the monitored resource group:
```
az vm list -g <resource-group> --query "[].{name:name, powerState:powerState, size:hardwareProfile.vmSize}" -o table
```

Check current power state and provisioning status for each VM.

## Step 2: Gather Performance Metrics

Query the Perf table in Log Analytics for CPU, memory, disk, and network counters:

```kql
Perf
| where TimeGenerated > ago(1h)
| where ObjectName == "Processor" and CounterName == "% Processor Time"
| summarize AvgCPU = avg(CounterValue), MaxCPU = max(CounterValue) by Computer, bin(TimeGenerated, 5m)
| order by AvgCPU desc
```

```kql
Perf
| where TimeGenerated > ago(1h)
| where ObjectName == "Memory" and CounterName == "% Used Memory"
| summarize AvgMem = avg(CounterValue), MaxMem = max(CounterValue) by Computer, bin(TimeGenerated, 5m)
| order by AvgMem desc
```

```kql
Perf
| where TimeGenerated > ago(1h)
| where ObjectName == "LogicalDisk" and CounterName == "% Free Space"
| where InstanceName != "_Total"
| summarize MinFreeSpace = min(CounterValue) by Computer, InstanceName
| where MinFreeSpace < 20
| order by MinFreeSpace asc
```

```kql
Perf
| where TimeGenerated > ago(1h)
| where ObjectName == "Network Adapter" and CounterName == "Bytes Total/sec"
| summarize AvgNetBytes = avg(CounterValue) by Computer, InstanceName, bin(TimeGenerated, 5m)
| order by AvgNetBytes desc
```

## Step 3: Check for Anomalies

Look for sudden spikes or sustained high utilization:
- CPU > 90% for more than 10 minutes
- Memory > 95% sustained
- Disk free space < 10%
- Network errors or drops

```kql
Perf
| where TimeGenerated > ago(4h)
| where ObjectName == "Processor" and CounterName == "% Processor Time"
| summarize AvgCPU = avg(CounterValue) by Computer, bin(TimeGenerated, 15m)
| where AvgCPU > 90
```

## Step 4: Check Azure Activity Logs

Look for recent changes that could cause performance issues:
```
az monitor activity-log list -g <resource-group> --offset 24h --query "[?status.value=='Succeeded'].{op:operationName.localizedValue, time:eventTimestamp, caller:caller}" -o table
```

Watch for: VM resizes, disk changes, extension installs, NSG rule modifications, restart events.

## Step 5: Check VM Extensions and Diagnostics

```
az vm extension list -g <resource-group> --vm-name <vm-name> -o table
az vm get-instance-view -g <resource-group> -n <vm-name> --query "instanceView.statuses[*].{code:code, message:message}" -o table
```

## Step 6: Check VM Boot Diagnostics

```
az vm boot-diagnostics get-boot-log -g <resource-group> -n <vm-name>
```

Look for kernel panics, filesystem errors, or service startup failures.

## Step 7: Recommend Remediation

Based on findings, recommend:
- **High CPU**: Identify top processes, consider scaling up VM size or scaling out
- **High Memory**: Check for memory leaks, increase VM size, or add swap
- **Low Disk**: Clean up temp files, expand disk, or attach additional disks
- **Network Issues**: Check NSG rules, verify DNS resolution, check NIC configuration
- **Extension Failures**: Reinstall or update problematic extensions
- **Recent Changes**: Correlate performance degradation with activity log events

Always search the knowledge base (`SearchMemory`) for existing runbooks before recommending remediation.

## Output

Provide a structured summary:
1. **Affected VMs**: List with current status
2. **Key Metrics**: CPU, memory, disk, network findings
3. **Anomalies Detected**: Time-correlated events
4. **Root Cause Hypothesis**: Based on evidence
5. **Recommended Actions**: Prioritized remediation steps
