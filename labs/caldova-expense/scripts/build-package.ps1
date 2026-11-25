<#
.SYNOPSIS
    Publishes the Caldova Expense .NET 8 web app and builds CaldovaExpense.zip for one-command IIS deployment.

.EXAMPLE
    .\scripts\build-package.ps1
    .\scripts\build-package.ps1 -OutputZip .\artifacts\CaldovaExpense.zip
#>
[CmdletBinding()]
param(
    [string] $Configuration = "Release",
    [string] $OutputZip = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$appProj  = Join-Path $repoRoot "app\CaldovaExpense.csproj"
$sqlFile  = Join-Path $repoRoot "sql\init-caldova-expense.sql"

if (-not $OutputZip) {
    $OutputZip = Join-Path $repoRoot "CaldovaExpense.zip"
}

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "dotnet SDK is required to build CaldovaExpense.zip. Install .NET 8 SDK or higher."
}

$stagingDir = Join-Path ([System.IO.Path]::GetTempPath()) ("caldova-expense-publish-" + [guid]::NewGuid().ToString("N"))

try {
    Write-Host "[1/3] Publishing CaldovaExpense ($Configuration)..." -ForegroundColor Cyan
    & dotnet publish $appProj -c $Configuration -o $stagingDir --nologo
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed with exit code $LASTEXITCODE."
    }

    # Bundle SQL init script inside _deploy/ so remote Arc Run-Command updates are 100% self-contained
    $deployMetaDir = Join-Path $stagingDir "_deploy"
    New-Item -ItemType Directory -Force -Path $deployMetaDir | Out-Null
    Copy-Item -Path $sqlFile -Destination (Join-Path $deployMetaDir "init-caldova-expense.sql") -Force

    $versionInfo = @{
        package       = "CaldovaExpense"
        builtAtUtc    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        configuration = $Configuration
        gitCommit     = (& git -C $repoRoot rev-parse --short HEAD 2>$null)
    }
    $versionInfo | ConvertTo-Json | Set-Content -Path (Join-Path $deployMetaDir "build-info.json") -Encoding utf8

    $outParent = Split-Path -Parent ([System.IO.Path]::GetFullPath($OutputZip))
    if ($outParent -and -not (Test-Path $outParent)) {
        New-Item -ItemType Directory -Force -Path $outParent | Out-Null
    }
    if (Test-Path $OutputZip) {
        Remove-Item -Path $OutputZip -Force
    }

    Write-Host "[2/3] Creating archive $OutputZip..." -ForegroundColor Cyan
    Compress-Archive -Path (Join-Path $stagingDir "*") -DestinationPath $OutputZip -CompressionLevel Optimal -Force

    $sizeMb = [math]::Round((Get-Item $OutputZip).Length / 1MB, 2)
    Write-Host "[3/3] Package ready: $OutputZip ($sizeMb MB)" -ForegroundColor Green
}
finally {
    if (Test-Path $stagingDir) {
        Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
