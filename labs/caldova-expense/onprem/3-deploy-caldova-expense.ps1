<#
.SYNOPSIS
    Step 3 (On-Prem Windows Server): One-command ZIP deploy of CaldovaExpense.zip into IIS,
    Windows Event Log source registration ('CaldovaExpense'), ACL configuration, health check,
    and optional baseline traffic Scheduled Task setup.

.EXAMPLE
    .\onprem\3-deploy-caldova-expense.ps1 -ZipPath .\CaldovaExpense.zip
    .\onprem\3-deploy-caldova-expense.ps1 -ZipUri "https://<storage>.blob.core.windows.net/releases/CaldovaExpense.zip?<sas>"
#>
[CmdletBinding()]
param(
    [string] $ZipPath = "",
    [string] $ZipUri = "",
    [string] $PhysicalPath = "C:\inetpub\caldova-expense",
    [string] $SiteName = "CaldovaExpense",
    [string] $AppPoolName = "CaldovaExpensePool",
    [int]    $Port = 8080,
    [string] $SqlServerInstance = "",
    [bool]   $EnableBaselineTraffic = $true
)

$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    throw "Run 3-deploy-caldova-expense.ps1 from an Administrator PowerShell session."
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

$downloadedTempZip = $null
try {
    if ($ZipUri) {
        $downloadedTempZip = Join-Path $env:TEMP ("CaldovaExpense-" + [guid]::NewGuid().ToString("N") + ".zip")
        Write-Host "Downloading package from URI to $downloadedTempZip..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $ZipUri -OutFile $downloadedTempZip -UseBasicParsing
        $ZipPath = $downloadedTempZip
    }
    elseif (-not $ZipPath) {
        $defaultRootZip = Join-Path (Split-Path -Parent $PSScriptRoot) "CaldovaExpense.zip"
        $localZip = Join-Path $PWD "CaldovaExpense.zip"
        if (Test-Path $localZip) {
            $ZipPath = $localZip
        }
        elseif (Test-Path $defaultRootZip) {
            $ZipPath = $defaultRootZip
        }
        else {
            throw "CaldovaExpense.zip not found. Build it first with .\scripts\build-package.ps1 or pass -ZipPath / -ZipUri."
        }
    }

    if (-not (Test-Path $ZipPath)) {
        throw "Package file not found at '$ZipPath'."
    }

    # Register Windows Event Log source 'CaldovaExpense' under Application log
    if (-not [System.Diagnostics.EventLog]::SourceExists("CaldovaExpense")) {
        Write-Host "Registering Windows Event Log source 'CaldovaExpense' (Application)..." -ForegroundColor Cyan
        [System.Diagnostics.EventLog]::CreateEventSource("CaldovaExpense", "Application")
    }

    # Prepare data/log directories and grant Modify permissions to IIS AppPool identity
    $dataRoot = "C:\ProgramData\CaldovaExpense"
    $logsRoot = Join-Path $dataRoot "logs"
    New-Item -ItemType Directory -Force -Path $logsRoot | Out-Null

    Import-Module WebAdministration

    if (-not (Test-Path "IIS:\AppPools\$AppPoolName")) {
        New-WebAppPool -Name $AppPoolName | Out-Null
    }
    Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name "managedRuntimeVersion" -Value ""
    Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name "managedPipelineMode" -Value "Integrated"

    # Stop AppPool briefly before overwriting locked DLLs
    $poolState = (Get-WebAppPoolState -Name $AppPoolName -ErrorAction SilentlyContinue).Value
    if ($poolState -eq "Started") {
        Write-Host "Stopping Application Pool '$AppPoolName' for clean ZIP extraction..." -ForegroundColor Cyan
        Stop-WebAppPool -Name $AppPoolName
        Start-Sleep -Seconds 2
    }

    Write-Host "Extracting '$ZipPath' -> '$PhysicalPath'..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path $PhysicalPath | Out-Null
    Expand-Archive -Path $ZipPath -DestinationPath $PhysicalPath -Force

    # Configure SQL instance override in appsettings.Production.json if detected by Step 2 or passed explicitly
    $savedInstanceFile = Join-Path $dataRoot "sql-instance.txt"
    if (-not $SqlServerInstance -and (Test-Path $savedInstanceFile)) {
        $SqlServerInstance = (Get-Content -Path $savedInstanceFile -Raw).Trim()
    }
    if (-not $SqlServerInstance) {
        $SqlServerInstance = "localhost,1433"
    }

    $prodSettings = @{
        ConnectionStrings = @{
            CaldovaExpenseDb = "Server=$SqlServerInstance;Database=CaldovaExpenseDb;Integrated Security=True;TrustServerCertificate=True;Connect Timeout=5;"
        }
    }
    $prodSettings | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $PhysicalPath "appsettings.Production.json") -Encoding utf8

    # Grant IIS APPPOOL\<AppPoolName> ReadAndExecute on PhysicalPath and Modify on C:\ProgramData\CaldovaExpense
    & icacls.exe $PhysicalPath /grant "IIS APPPOOL\${AppPoolName}:(OI)(CI)RX" /T /Q | Out-Null
    & icacls.exe $dataRoot /grant "IIS APPPOOL\${AppPoolName}:(OI)(CI)M" /T /Q | Out-Null

    # Create or update IIS Website on Port 8080
    $existingSite = Get-Website -Name $SiteName -ErrorAction SilentlyContinue
    if (-not $existingSite) {
        Write-Host "Creating IIS Website '$SiteName' on port $Port..." -ForegroundColor Cyan
        New-Website -Name $SiteName -Port $Port -PhysicalPath $PhysicalPath -ApplicationPool $AppPoolName -Force | Out-Null
    }
    else {
        Set-ItemProperty "IIS:\Sites\$SiteName" -Name "physicalPath" -Value $PhysicalPath
        Set-ItemProperty "IIS:\Sites\$SiteName" -Name "applicationPool" -Value $AppPoolName
        $binding = Get-WebBinding -Name $SiteName -Protocol "http" -ErrorAction SilentlyContinue
        if (-not $binding) {
            New-WebBinding -Name $SiteName -Protocol "http" -Port $Port -IPAddress "*" | Out-Null
        }
    }

    # Ensure W3C logging fields are active on the site
    $logFlags = "Date,Time,ClientIP,UserName,ServerIP,Method,UriStem,UriQuery,HttpStatus,HttpSubStatus,Win32Status,BytesSent,BytesRecv,TimeTaken,ServerPort,UserAgent,Host"
    Set-ItemProperty "IIS:\Sites\$SiteName" -Name "logFile.logFormat" -Value "W3C"
    Set-ItemProperty "IIS:\Sites\$SiteName" -Name "logFile.directory" -Value "C:\inetpub\logs\LogFiles"
    Set-ItemProperty "IIS:\Sites\$SiteName" -Name "logFile.logExtFileFlags" -Value $logFlags

    Start-WebAppPool -Name $AppPoolName
    Start-Website -Name $SiteName

    # Ensure chaos mode defaults to normal on fresh deploy if not set
    $chaosFile = Join-Path $dataRoot "chaos.json"
    if (-not (Test-Path $chaosFile)) {
        @{ mode = "normal"; updatedUtc = (Get-Date).ToUniversalTime().ToString("o"); notes = "Initial deployment" } |
            ConvertTo-Json | Set-Content -Path $chaosFile -Encoding utf8
    }

    Write-Host "Warming up http://localhost:$Port/api/health..." -ForegroundColor Cyan
    Start-Sleep -Seconds 2
    $healthResp = Invoke-WebRequest -Uri "http://localhost:$Port/api/health" -UseBasicParsing -TimeoutSec 15
    Write-Host "Health check HTTP $($healthResp.StatusCode): $($healthResp.Content)" -ForegroundColor Green

    # Optional baseline traffic Scheduled Task so W3CIISLog + Perf + App logs continuously emit baseline records
    $trafficScript = Join-Path $PSScriptRoot "start-traffic-generator.ps1"
    if ($EnableBaselineTraffic -and (Test-Path $trafficScript)) {
        & $trafficScript -Port $Port
    }

    Write-Host "`nStep 3 complete! Caldova Expense is live at http://localhost:$Port/" -ForegroundColor Green
}
finally {
    if ($downloadedTempZip -and (Test-Path $downloadedTempZip)) {
        Remove-Item -Path $downloadedTempZip -Force -ErrorAction SilentlyContinue
    }
}
