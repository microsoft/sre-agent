---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: disk-pressure-diagnosis
description: Diagnose and remediate disk pressure on Windows Azure VMs. Investigates disk usage, identifies large files, old backups, runaway logs, and recommends cleanup or disk expansion. Use when disk utilization alerts fire or a VM reports low free space.
---

# Disk Pressure Diagnosis (Windows)

## Overview
Investigate and remediate disk space issues on Windows Azure VMs (including Arc-enabled servers).

## Run-Command Guidelines

**Variable escaping**: When passing PowerShell via `az vm run-command invoke --scripts`, variables like `$_` and `$PSItem` are mangled by intermediate shell layers. Use these safe patterns:
- `foreach ($var in $collection)` with named variables — never `ForEach-Object { $_ }`
- `Select-Object PropertyName` with direct property names — never calculated properties `@{E={$_...}}`
- `Where-Object PropertyName -eq Value` (simplified syntax) — never `Where-Object { $_.Prop }`
- `Get-CimInstance` for WMI queries that return clean tabular output without pipeline variables

**Output limits**: Run Command returns only the last ~4096 bytes. Always use `Select-Object -First N` or targeted queries. Never scan all of C:\ recursively — target specific directories.

**Serial execution (v1)**: Only one `invoke` runs at a time per VM. If a previous command is stuck or timed out, new invocations will block. Use the v2 managed run-command API as a fallback:
```bash
# Create a named run-command (runs independently of the v1 queue)
az vm run-command create --resource-group <RG> --vm-name <VM_NAME> \
  --name <UNIQUE_NAME> --location <LOCATION> \
  --script "Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Format-List DeviceID, Size, FreeSpace"

# Check result
az vm run-command show --resource-group <RG> --vm-name <VM_NAME> \
  --name <UNIQUE_NAME> --instance-view

# Clean up afterward (mandatory — this creates a persistent ARM resource)
az vm run-command delete --resource-group <RG> --vm-name <VM_NAME> \
  --name <UNIQUE_NAME> --yes
```

## Phase 1: Detect — Confirm Disk Pressure

### Check disk utilization
```bash
az vm run-command invoke --resource-group <RG> --name <VM_NAME> \
  --command-id RunPowerShellScript \
  --scripts "Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Format-List DeviceID, Size, FreeSpace"
```
Compute used percentage from raw Size and FreeSpace values. Warning threshold: above 85% used. Critical: above 95% used.

### Check disk metrics in Azure Monitor
```kql
InsightsMetrics
| where Namespace == "LogicalDisk" and Name == "FreeSpacePercentage"
| where Computer contains "<VM_NAME>"
| where TimeGenerated > ago(24h)
| summarize avg(Val) by bin(TimeGenerated, 1h), Tags
| order by TimeGenerated desc
```

## Phase 2: Investigate — Find What Is Using Space

### List top-level directories
```bash
az vm run-command invoke --resource-group <RG> --name <VM_NAME> \
  --command-id RunPowerShellScript \
  --scripts "Get-ChildItem C:\ -Directory -ErrorAction SilentlyContinue | Select-Object Name"
```

### Check size of a specific directory
Run this per suspect directory. Do NOT scan all of C:\ recursively — it will timeout.
```bash
az vm run-command invoke --resource-group <RG> --name <VM_NAME> \
  --command-id RunPowerShellScript \
  --scripts "Get-ChildItem C:\data -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum"
```

### Find large files in a directory
```bash
az vm run-command invoke --resource-group <RG> --name <VM_NAME> \
  --command-id RunPowerShellScript \
  --scripts "Get-ChildItem C:\data -Recurse -File -ErrorAction SilentlyContinue | Sort-Object Length -Descending | Select-Object -First 20 FullName, Length"
```

### Common Windows culprits
- `C:\data` — application data, backups, database dumps
- `C:\Windows\Temp` — temporary installer files
- `C:\Windows\Logs\CBS` — component servicing logs
- `C:\Windows\SoftwareDistribution` — Windows Update cache
- `C:\inetpub\logs` — IIS access logs
- `C:\Users\*\AppData\Local\Temp` — user temp files
- `C:\ProgramData` — application state and logs

## Phase 3: Root Cause — Classify the Problem

| Pattern | Likely Cause | Check |
|---|---|---|
| Large .bak/.dump files in C:\data | Backup retention not configured | Is there a scheduled task? Is retention set? |
| Single giant .log file | App logging at DEBUG/TRACE level | Check app log config |
| C:\Windows\SoftwareDistribution large | Windows Update cache buildup | Run Dism cleanup |
| C:\Windows\Temp growing | Failed installers or stale temp | Check file ages |
| Sudden spike in usage | One-time event (dump, export, failed job) | Check timestamps of large files |
| Steady growth over days | Data accumulation without cleanup | Check scheduled task outputs |

## Phase 4: Remediate

### Option A: Clean up (after confirming files are safe to delete)
```bash
az vm run-command invoke --resource-group <RG> --name <VM_NAME> \
  --command-id RunPowerShellScript \
  --scripts "
    Remove-Item C:\data\scada-backups\*.bak -Force -ErrorAction SilentlyContinue
    Remove-Item C:\data\grid-logs\*.log -Force -ErrorAction SilentlyContinue
    Remove-Item C:\data\grid-logs\*.tmp -Force -ErrorAction SilentlyContinue
    Remove-Item C:\Windows\Temp\* -Recurse -Force -ErrorAction SilentlyContinue
    Write-Output 'Cleanup complete.'
  "
```

### Option B: Expand disk
```bash
# Check current disk size
az disk show --resource-group <RG> --name <DISK_NAME> --query diskSizeGb

# Expand (can only increase, not decrease)
az disk update --resource-group <RG> --name <DISK_NAME> --size-gb <NEW_SIZE>

# Then extend the partition inside the VM
az vm run-command invoke --resource-group <RG> --name <VM_NAME> \
  --command-id RunPowerShellScript \
  --scripts "
    $maxSize = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
    Resize-Partition -DriveLetter C -Size $maxSize
    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Format-List DeviceID, Size, FreeSpace
  "
```

## Phase 5: Validate
```bash
az vm run-command invoke --resource-group <RG> --name <VM_NAME> \
  --command-id RunPowerShellScript \
  --scripts "Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Format-List DeviceID, Size, FreeSpace"
```
Confirm target drive is below 80% used.
