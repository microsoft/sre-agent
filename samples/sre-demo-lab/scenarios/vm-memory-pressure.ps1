<#
.SYNOPSIS
    Generates memory pressure on a VM for SRE Agent demo.

.PARAMETER ResourceGroupName
    Name of the resource group. Default: infra-sre-demo-rg

.PARAMETER VMName
    Name of the VM to stress. If not specified, uses first VM in RG.

.PARAMETER DurationMinutes
    Duration of stress test in minutes. Default: 15

.PARAMETER MemoryPercent
    Percentage of memory to allocate. Default: 80

.EXAMPLE
    ./vm-memory-pressure.ps1 -VMName "vm-sre-demo-01" -DurationMinutes 10
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = "infra-sre-demo-rg",

    [Parameter(Mandatory = $false)]
    [string]$VMName,

    [Parameter(Mandatory = $false)]
    [int]$DurationMinutes = 15,

    [Parameter(Mandatory = $false)]
    [int]$MemoryPercent = 80
)

$ErrorActionPreference = "Stop"

# Get VM
if (-not $VMName) {
    $vm = az vm list -g $ResourceGroupName --query "[0].name" -o tsv
    if (-not $vm) {
        Write-Error "No VMs found in resource group: $ResourceGroupName"
    }
    $VMName = $vm
}

Write-Host "Generating memory pressure on VM: $VMName" -ForegroundColor Cyan
Write-Host "  Memory allocation: $MemoryPercent%" -ForegroundColor Gray
Write-Host "  Duration: $DurationMinutes minutes" -ForegroundColor Gray

# Get public IP
$publicIp = az vm show -g $ResourceGroupName -n $VMName -d --query publicIps -o tsv

# SSH key path
$sshKeyPath = "$env:USERPROFILE\.ssh\sre-demo-key"

# Run stress-ng for memory
$command = "nohup stress-ng --vm 1 --vm-bytes ${MemoryPercent}% --timeout ${DurationMinutes}m > /dev/null 2>&1 &"
ssh -i $sshKeyPath -o StrictHostKeyChecking=no azureuser@$publicIp $command

Write-Host "✓ Memory stress started on $VMName" -ForegroundColor Green
Write-Host "  Monitor in Azure: Portal > $VMName > Monitoring > Metrics > Available Memory" -ForegroundColor Yellow
