<#
.SYNOPSIS
  Disk scenario: fills the reporting-worker VM's data disk (/data) so the nightly
  grade-export job can no longer write its export files and fails with "No space left
  on device". This is live operational drift on the VM (no IaC change): the export
  worker keeps running on its timer but every cycle now fails, which the symptom-only
  Azure Monitor alert (Zava-grade-exports-failing) pages on. The SRE Agent must diagnose
  the disk-pressure root cause from Syslog / disk telemetry and free space (fix-disk.ps1).
#>
param(
  [string]$ResourceGroup = "rg-zava-learning-demo"
)
. "$PSScriptRoot\_common.ps1"

$vm = Get-ReportingVmName -ResourceGroup $ResourceGroup
Write-Host "[break-disk] Filling /data on $vm so grade exports start failing..." -ForegroundColor Yellow

# The export worker only runs when the VM is up; ensure it is running (and not deallocated)
# before we fill the disk, otherwise the fault would silently no-op.
$power = az vm show -d -g $ResourceGroup -n $vm --query powerState -o tsv 2>$null
if ($power -ne "VM running") {
  Write-Host "  VM power state is '$power' — starting it before injecting the fault..." -ForegroundColor Gray
  az vm start -g $ResourceGroup -n $vm -o none
  if ($LASTEXITCODE -ne 0) {
    throw "[break-disk] Could not start $vm (power state was '$power'). The grade-export worker cannot run, so the disk-pressure fault was NOT injected. Resolve the VM start failure (e.g. SKU/capacity) and re-run."
  }
  Start-Sleep -Seconds 60
}

$script = "sudo bash -c 'dd if=/dev/zero of=/data/exports/backlog.bin bs=1M 2>/tmp/zava-fill.log; tail -n 2 /tmp/zava-fill.log; df -h /data'"
$out = az vm run-command invoke -g $ResourceGroup -n $vm --command-id RunShellScript --scripts "$script" `
  --query "value[0].message" -o tsv
# az returns the multi-line message as a string[] in PowerShell; collapse to one string so the
# checks below are boolean tests, not array filters.
$out = ($out | Out-String)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($out)) {
  throw "[break-disk] The disk-fill command failed on $vm (no output). Fault NOT injected — check the VM and /data mount."
}
Write-Host $out

# Confirm the fault actually took effect: the disk must be full (dd hit ENOSPC or df shows 100%).
if ($out -notmatch "No space left on device" -and $out -notmatch "100%") {
  throw "[break-disk] /data did NOT fill up on $vm (no ENOSPC / not 100% — see output above). The fault did not take effect; the grade exports will keep succeeding. Verify the dedicated 8 GB data disk is mounted at /data and re-run."
}

Write-Host "[break-disk] Data disk filled. The grade-export job will fail on its next run." -ForegroundColor Red

# Page PagerDuty with a clean, symptom-only incident — exactly like every other lane's break
# script. (The Zava-grade-exports-failing Azure Monitor rule still detects the symptom in the
# portal as supporting evidence, but it no longer routes to PagerDuty, so the on-call sees one
# readable incident instead of a raw common-alert-schema JSON blob.)
New-PagerDutyIncident -Title "Zava reporting — nightly grade exports are failing" `
  -Details ("The reporting worker's nightly grade-export job has started failing on every cycle; no new " +
            "export files have been produced since the failures began. Instructors and the downstream " +
            "analytics pipeline are now working from stale grade data. Investigate why the export job can " +
            "no longer complete on the reporting-worker VM.") | Out-Null
