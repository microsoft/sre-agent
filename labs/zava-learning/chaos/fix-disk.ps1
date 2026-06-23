<#
.SYNOPSIS
  Disk scenario fix: frees space on the reporting-worker VM's data disk by removing the
  backlog fill file so the nightly grade-export job can write again and recovers.
#>
param(
  [string]$ResourceGroup = "rg-zava-learning-demo"
)
. "$PSScriptRoot\_common.ps1"

$vm = Get-ReportingVmName -ResourceGroup $ResourceGroup
Write-Host "[fix-disk] Freeing space on /data on $vm..." -ForegroundColor Yellow

$script = "sudo bash -c 'rm -f /data/exports/backlog.bin; df -h /data'"
az vm run-command invoke -g $ResourceGroup -n $vm --command-id RunShellScript --scripts "$script" `
  --query "value[0].message" -o tsv

Write-Host "[fix-disk] Disk space reclaimed. Grade exports should succeed on the next run." -ForegroundColor Green
