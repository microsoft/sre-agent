<#
.SYNOPSIS
    Generates all problem scenarios for the SRE Demo Lab.

.DESCRIPTION
    This script runs stress tests on VMs and triggers backup failures
    to create troubleshooting scenarios for SRE Agent demonstration.

.PARAMETER ResourceGroupName
    Name of the resource group. Default: infra-sre-demo-rg

.PARAMETER DurationMinutes
    Duration for stress tests in minutes. Default: 15

.PARAMETER SkipCpuSpike
    Skip CPU spike generation.

.PARAMETER SkipMemoryPressure
    Skip memory pressure generation.

.PARAMETER SkipDiskStress
    Skip disk stress generation.

.PARAMETER SkipBackupFailure
    Skip backup failure trigger.

.EXAMPLE
    ./generate-problems.ps1

.EXAMPLE
    ./generate-problems.ps1 -DurationMinutes 30 -SkipBackupFailure
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = "infra-sre-demo-rg",

    [Parameter(Mandatory = $false)]
    [int]$DurationMinutes = 15,

    [Parameter(Mandatory = $false)]
    [switch]$SkipCpuSpike,

    [Parameter(Mandatory = $false)]
    [switch]$SkipMemoryPressure,

    [Parameter(Mandatory = $false)]
    [switch]$SkipDiskStress,

    [Parameter(Mandatory = $false)]
    [switch]$SkipBackupFailure
)

$ErrorActionPreference = "Stop"

# =============================================================================
# Helper Functions
# =============================================================================

function Write-Step {
    param([string]$Message)
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "✓ $Message" -ForegroundColor Green
}

function Write-Info {
    param([string]$Message)
    Write-Host "ℹ $Message" -ForegroundColor Yellow
}

# =============================================================================
# Get VMs
# =============================================================================

Write-Step "Discovering VMs in resource group: $ResourceGroupName"

$vms = az vm list -g $ResourceGroupName --query "[].{name:name, id:id}" -o json | ConvertFrom-Json
if ($vms.Count -eq 0) {
    Write-Error "No VMs found in resource group: $ResourceGroupName"
}

Write-Success "Found $($vms.Count) VMs"

# Get SSH key path
$sshKeyPath = "$env:USERPROFILE\.ssh\sre-demo-key"
if (-not (Test-Path $sshKeyPath)) {
    Write-Error "SSH key not found at: $sshKeyPath. Please run deploy.ps1 first."
}

# =============================================================================
# Generate CPU Spike
# =============================================================================

if (-not $SkipCpuSpike) {
    Write-Step "Scenario 1: Generate CPU Spike"
    
    $vm = $vms[0]
    $publicIp = az vm show -g $ResourceGroupName -n $vm.name -d --query publicIps -o tsv
    
    Write-Info "Target VM: $($vm.name) ($publicIp)"
    Write-Info "Duration: $DurationMinutes minutes"
    
    # Run stress-ng for CPU
    $cpuCommand = "nohup stress-ng --cpu 0 --cpu-load 95 --timeout ${DurationMinutes}m > /dev/null 2>&1 &"
    
    ssh -i $sshKeyPath -o StrictHostKeyChecking=no azureuser@$publicIp $cpuCommand
    
    Write-Success "CPU stress started on $($vm.name)"
}

# =============================================================================
# Generate Memory Pressure
# =============================================================================

if (-not $SkipMemoryPressure) {
    Write-Step "Scenario 2: Generate Memory Pressure"
    
    $vm = $vms[0]
    $publicIp = az vm show -g $ResourceGroupName -n $vm.name -d --query publicIps -o tsv
    
    Write-Info "Target VM: $($vm.name) ($publicIp)"
    Write-Info "Duration: $DurationMinutes minutes"
    
    # Run stress-ng for memory (allocate 80% of memory)
    $memCommand = "nohup stress-ng --vm 1 --vm-bytes 80% --timeout ${DurationMinutes}m > /dev/null 2>&1 &"
    
    ssh -i $sshKeyPath -o StrictHostKeyChecking=no azureuser@$publicIp $memCommand
    
    Write-Success "Memory stress started on $($vm.name)"
}

# =============================================================================
# Generate Disk I/O Stress
# =============================================================================

if (-not $SkipDiskStress) {
    Write-Step "Scenario 3: Generate Disk I/O Stress"
    
    $vm = if ($vms.Count -gt 1) { $vms[1] } else { $vms[0] }
    $publicIp = az vm show -g $ResourceGroupName -n $vm.name -d --query publicIps -o tsv
    
    Write-Info "Target VM: $($vm.name) ($publicIp)"
    Write-Info "Duration: $DurationMinutes minutes"
    
    # Run fio for disk I/O stress
    $diskCommand = @"
nohup bash -c 'timeout ${DurationMinutes}m fio --name=stress --ioengine=libaio --rw=randrw --bs=4k --direct=1 --size=1G --numjobs=4 --runtime=$($DurationMinutes * 60) --time_based --filename=/tmp/fio-test' > /dev/null 2>&1 &
"@
    
    ssh -i $sshKeyPath -o StrictHostKeyChecking=no azureuser@$publicIp $diskCommand
    
    Write-Success "Disk I/O stress started on $($vm.name)"
    
    # Also fill disk space
    Write-Info "Creating large files to reduce disk space..."
    $fillCommand = "dd if=/dev/zero of=/tmp/largefile bs=100M count=20 2>/dev/null &"
    ssh -i $sshKeyPath -o StrictHostKeyChecking=no azureuser@$publicIp $fillCommand
    
    Write-Success "Disk space reduction started on $($vm.name)"
}

# =============================================================================
# Trigger Backup Failure
# =============================================================================

if (-not $SkipBackupFailure) {
    Write-Step "Scenario 4: Trigger Backup Failure"
    
    & "$PSScriptRoot\backup-failure.ps1" -ResourceGroupName $ResourceGroupName -TriggerFailure
    
    Write-Success "Backup failure scenario configured"
}

# =============================================================================
# Summary
# =============================================================================

Write-Step "Problem Scenarios Generated!"

Write-Host "`nActive Scenarios:" -ForegroundColor White
if (-not $SkipCpuSpike) {
    Write-Host "  • CPU Spike: $($vms[0].name) - 95% CPU for $DurationMinutes minutes" -ForegroundColor Gray
}
if (-not $SkipMemoryPressure) {
    Write-Host "  • Memory Pressure: $($vms[0].name) - 80% memory allocation" -ForegroundColor Gray
}
if (-not $SkipDiskStress) {
    $diskVm = if ($vms.Count -gt 1) { $vms[1].name } else { $vms[0].name }
    Write-Host "  • Disk I/O: $diskVm - High IOPS + disk fill" -ForegroundColor Gray
}
if (-not $SkipBackupFailure) {
    Write-Host "  • Backup Failure: NSG blocking Azure Backup service" -ForegroundColor Gray
}

Write-Host "`nMetrics will appear in Azure Monitor within 2-5 minutes." -ForegroundColor Yellow
Write-Host "Use SRE Agent to detect and troubleshoot these issues.`n" -ForegroundColor Yellow
