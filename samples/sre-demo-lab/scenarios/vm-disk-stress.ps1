<#
.SYNOPSIS
    Generates disk I/O stress and fills disk on a VM for SRE Agent demo.

.PARAMETER ResourceGroupName
    Name of the resource group. Default: infra-sre-demo-rg

.PARAMETER VMName
    Name of the VM to stress. If not specified, uses second VM in RG.

.PARAMETER DurationMinutes
    Duration of stress test in minutes. Default: 15

.PARAMETER FillDiskGB
    Amount of disk space to fill in GB. Default: 2

.EXAMPLE
    ./vm-disk-stress.ps1 -VMName "vm-sre-demo-02" -DurationMinutes 10 -FillDiskGB 3
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
    [int]$FillDiskGB = 2
)

$ErrorActionPreference = "Stop"

# Get VM (prefer second VM if available)
if (-not $VMName) {
    $vms = az vm list -g $ResourceGroupName --query "[].name" -o json | ConvertFrom-Json
    if ($vms.Count -eq 0) {
        Write-Error "No VMs found in resource group: $ResourceGroupName"
    }
    $VMName = if ($vms.Count -gt 1) { $vms[1] } else { $vms[0] }
}

Write-Host "Generating disk stress on VM: $VMName" -ForegroundColor Cyan
Write-Host "  I/O Duration: $DurationMinutes minutes" -ForegroundColor Gray
Write-Host "  Disk Fill: ${FillDiskGB}GB" -ForegroundColor Gray

# Get public IP
$publicIp = az vm show -g $ResourceGroupName -n $VMName -d --query publicIps -o tsv

# SSH key path
$sshKeyPath = "$env:USERPROFILE\.ssh\sre-demo-key"

# Run fio for disk I/O stress
$ioCommand = "nohup bash -c 'timeout ${DurationMinutes}m fio --name=stress --ioengine=libaio --rw=randrw --bs=4k --direct=1 --size=500M --numjobs=4 --runtime=$($DurationMinutes * 60) --time_based --filename=/tmp/fio-test' > /dev/null 2>&1 &"
ssh -i $sshKeyPath -o StrictHostKeyChecking=no azureuser@$publicIp $ioCommand

Write-Host "✓ Disk I/O stress started on $VMName" -ForegroundColor Green

# Fill disk space
$fillCount = $FillDiskGB * 10  # 100MB blocks
$fillCommand = "dd if=/dev/zero of=/tmp/largefile bs=100M count=$fillCount 2>/dev/null &"
ssh -i $sshKeyPath -o StrictHostKeyChecking=no azureuser@$publicIp $fillCommand

Write-Host "✓ Disk fill started on $VMName (${FillDiskGB}GB)" -ForegroundColor Green
Write-Host "  Monitor in Azure: Portal > $VMName > Monitoring > Metrics > Disk IOPS / Free Space" -ForegroundColor Yellow
