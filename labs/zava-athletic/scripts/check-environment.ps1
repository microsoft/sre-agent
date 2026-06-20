#!/usr/bin/env pwsh
# Pre-provision environment check for the SRE Zava Demo.
# Fast-fails with a clear, actionable message if the host is missing required tooling.
#
# This demo currently requires PowerShell 7.4+ (Windows or WSL/Linux/macOS with pwsh installed)
# and `az` on PATH. kubectl is NOT required: the AKS cluster is private and every in-cluster
# operation runs through `az aks command invoke`. Post-provision automation runs in pwsh.

$ErrorActionPreference = 'Stop'

function Write-Fail($msg) {
    Write-Host ""
    Write-Host "ERROR: $msg" -ForegroundColor Red
    Write-Host ""
    Write-Host "This demo requires PowerShell 7.4+ (Windows, WSL, Linux, or macOS) and Azure CLI." -ForegroundColor Yellow
    Write-Host "Post-provision automation runs in pwsh." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

# 1. PowerShell version
if ($PSVersionTable.PSVersion.Major -lt 7 -or
   ($PSVersionTable.PSVersion.Major -eq 7 -and $PSVersionTable.PSVersion.Minor -lt 4)) {
    Write-Fail "PowerShell 7.4+ is required. Detected: $($PSVersionTable.PSVersion)"
}

# 2. Required CLI tools (kubectl intentionally NOT required — private cluster, all kubectl
#    calls go through `az aks command invoke`)
$required = @('az')
$missing = @()
foreach ($tool in $required) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        $missing += $tool
    }
}
if ($missing.Count -gt 0) {
    Write-Fail "Missing required CLI tools on PATH: $($missing -join ', ')"
}

# 3. Azure CLI must be logged in (azd provision / post-provision both rely on this)
$null = az account show 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Not logged in to Azure CLI. Run 'az login' first."
}

Write-Host "Environment check passed (pwsh $($PSVersionTable.PSVersion), az found and logged in)." -ForegroundColor Green
