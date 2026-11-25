<#
.SYNOPSIS
    Step 1 (On-Prem Windows Server): Enables IIS 10 + W3C Extended Logging, installs the .NET 8
    Windows Hosting Bundle, and ensures local SQL Server 2022 Express/Developer is installed.

.DESCRIPTION
    Run from an elevated PowerShell session on the non-Azure Windows Server 2022/2025 VM
    (e.g. win-caldova-exp01, 10.50.1.10/24). Keeps inbound firewall ports closed by default.

.EXAMPLE
    .\onprem\1-setup-windows-host.ps1
    .\onprem\1-setup-windows-host.ps1 -InstallSqlExpress:$false
#>
[CmdletBinding()]
param(
    [string] $AppPoolName = "CaldovaExpensePool",
    [bool]   $InstallHostingBundle = $true,
    [bool]   $InstallSqlExpress = $true,
    [switch] $AllowPrivateSubnetPort8080,
    [string] $AllowedRemoteSubnet = "10.40.0.0/13,10.50.1.0/24"
)

$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    throw "Run 1-setup-windows-host.ps1 from an Administrator PowerShell session."
}

# Ensure TLS 1.2+ for downloads in Windows PowerShell 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

Write-Host "=== [1/4] Installing IIS 10 Windows Server features ===" -ForegroundColor Cyan
$iisFeatures = @(
    "Web-Server", "Web-WebServer", "Web-Common-Http",
    "Web-Default-Doc", "Web-Http-Errors", "Web-Static-Content", "Web-Http-Logging",
    "Web-Request-Monitor", "Web-Http-Tracing", "Web-Stat-Compression",
    "Web-Security", "Web-Filtering", "Web-Windows-Auth",
    "Web-App-Dev", "Web-Net-Ext45", "Web-Asp-Net45", "Web-Mgmt-Console", "Web-Scripting-Tools"
)
Install-WindowsFeature -Name $iisFeatures -IncludeManagementTools | Out-Null

Import-Module WebAdministration

Write-Host "Configuring IIS W3C Extended Logging fields (time-taken, sc-status, sc-substatus, cs-uri-stem, ...)..." -ForegroundColor Cyan
$logFlags = "Date,Time,ClientIP,UserName,ServerIP,Method,UriStem,UriQuery,HttpStatus,HttpSubStatus,Win32Status,BytesSent,BytesRecv,TimeTaken,ServerPort,UserAgent,Host"
Set-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" `
    -Filter "system.applicationHost/sites/siteDefaults/logfile" `
    -Name "logFormat" -Value "W3C"
Set-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" `
    -Filter "system.applicationHost/sites/siteDefaults/logfile" `
    -Name "directory" -Value "C:\inetpub\logs\LogFiles"
Set-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" `
    -Filter "system.applicationHost/sites/siteDefaults/logfile" `
    -Name "logExtFileFlags" -Value $logFlags

# Pre-create CaldovaExpensePool so SQL Server can map [IIS APPPOOL\CaldovaExpensePool] in Step 2
if (-not (Test-Path "IIS:\AppPools\$AppPoolName")) {
    Write-Host "Creating IIS Application Pool '$AppPoolName' (No Managed Code, Integrated)..." -ForegroundColor Cyan
    New-WebAppPool -Name $AppPoolName | Out-Null
}
Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name "managedRuntimeVersion" -Value ""
Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name "managedPipelineMode" -Value "Integrated"
Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name "startMode" -Value "AlwaysRunning"

Write-Host "=== [2/4] Checking .NET 8 Windows Hosting Bundle (AspNetCoreModuleV2) ===" -ForegroundColor Cyan
$ancmDll = Join-Path $env:ProgramFiles "IIS\Asp.Net Core Module\V2\aspnetcorev2.dll"
$dotnetExe = Join-Path $env:ProgramFiles "dotnet\dotnet.exe"
$hasAspNet8 = $false
if (Test-Path $dotnetExe) {
    $runtimes = & $dotnetExe --list-runtimes 2>$null
    if ($runtimes -match "Microsoft\.AspNetCore\.App 8\.") {
        $hasAspNet8 = $true
    }
}

if ((-not (Test-Path $ancmDll) -or -not $hasAspNet8) -and $InstallHostingBundle) {
    $bundleInstaller = Join-Path $env:TEMP "dotnet-hosting-8.0-win.exe"
    Write-Host "Downloading .NET 8 Windows Hosting Bundle..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri "https://aka.ms/dotnet/8.0/dotnet-hosting-win.exe" -OutFile $bundleInstaller -UseBasicParsing
    Write-Host "Installing .NET 8 Windows Hosting Bundle (silent)..." -ForegroundColor Yellow
    $proc = Start-Process -FilePath $bundleInstaller -ArgumentList "/install", "/quiet", "/norestart" -Wait -PassThru
    if ($proc.ExitCode -notin @(0, 1638, 3010)) {
        throw ".NET 8 Hosting Bundle installer exited with code $($proc.ExitCode)."
    }
    Remove-Item -Path $bundleInstaller -Force -ErrorAction SilentlyContinue
    & net.exe stop was /y | Out-Null
    & net.exe start w3svc | Out-Null
    Write-Host ".NET 8 Hosting Bundle installed and IIS recycled." -ForegroundColor Green
}
else {
    Write-Host ".NET 8 ASP.NET Core Runtime and AspNetCoreModuleV2 already present." -ForegroundColor Green
}

Write-Host "=== [3/4] Checking local SQL Server instance ===" -ForegroundColor Cyan
$sqlServices = @(Get-Service -Name "MSSQLSERVER", "MSSQL`$SQLEXPRESS" -ErrorAction SilentlyContinue)
if ($sqlServices.Count -eq 0 -and $InstallSqlExpress) {
    Write-Host "No local SQL Server service detected. Downloading SQL Server 2022 Express bootstrapper..." -ForegroundColor Yellow
    $sqlSetupDir = Join-Path $env:TEMP "sql2022-express"
    New-Item -ItemType Directory -Force -Path $sqlSetupDir | Out-Null
    $sqlBootstrap = Join-Path $sqlSetupDir "SQL2022-SSEI-Expr.exe"
    $mediaPath    = Join-Path $sqlSetupDir "Media"

    Invoke-WebRequest -Uri "https://go.microsoft.com/fwlink/?linkid=866658" -OutFile $sqlBootstrap -UseBasicParsing
    Write-Host "Downloading SQL Server 2022 Express Core media..." -ForegroundColor Yellow
    $dlProc = Start-Process -FilePath $sqlBootstrap -ArgumentList "/Action=Download", "/Mediapath=`"$mediaPath`"", "/Mediatype=Core", "/Quiet" -Wait -PassThru
    if ($dlProc.ExitCode -ne 0) {
        throw "SQL Server Express media download failed with exit code $($dlProc.ExitCode)."
    }

    $extractedExe = Get-ChildItem -Path $mediaPath -Filter "SQLEXPR*.exe" | Select-Object -First 1
    if (-not $extractedExe) {
        throw "Could not locate downloaded SQLEXPR*.exe in $mediaPath."
    }

    $extractDir = Join-Path $sqlSetupDir "Extracted"
    Start-Process -FilePath $extractedExe.FullName -ArgumentList "/Q", "/X:`"$extractDir`"" -Wait | Out-Null
    $setupExe = Join-Path $extractDir "SETUP.EXE"

    Write-Host "Installing SQL Server 2022 Express as default instance (MSSQLSERVER, TCP 1433, Windows Auth)..." -ForegroundColor Yellow
    $installArgs = @(
        "/Q",
        "/ACTION=Install",
        "/FEATURES=SQLENGINE",
        "/INSTANCENAME=MSSQLSERVER",
        "/SQLSVCACCOUNT=`"NT Service\MSSQLSERVER`"",
        "/SQLSYSADMINACCOUNTS=`"BUILTIN\Administrators`" `"NT AUTHORITY\SYSTEM`"",
        "/TCPENABLED=1",
        "/NPENABLED=1",
        "/IACCEPTSQLSERVERLICENSETERMS"
    )
    $sqlProc = Start-Process -FilePath $setupExe -ArgumentList $installArgs -Wait -PassThru
    if ($sqlProc.ExitCode -notin @(0, 3010)) {
        throw "SQL Server 2022 Express installation failed with exit code $($sqlProc.ExitCode)."
    }

    Remove-Item -Path $sqlSetupDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "SQL Server 2022 Express installed as default instance (localhost,1433)." -ForegroundColor Green
}
else {
    foreach ($svc in $sqlServices) {
        if ($svc.Status -ne "Running") {
            Start-Service -Name $svc.Name
        }
        Write-Host "Detected running SQL Server service: $($svc.Name)" -ForegroundColor Green
    }
}

Write-Host "=== [4/4] Verifying inbound firewall posture ===" -ForegroundColor Cyan
if ($AllowPrivateSubnetPort8080) {
    $ruleName = "CaldovaExpense-PrivateSubnet-8080"
    $remoteAddresses = @($AllowedRemoteSubnet -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
            -Protocol TCP -LocalPort 8080 -RemoteAddress $remoteAddresses | Out-Null
        Write-Host "Added private-subnet firewall rule '$ruleName' for $($remoteAddresses -join ', ')." -ForegroundColor Green
    }
}
else {
    Write-Host "Inbound ports 8080, 1433, 3389, 5985 remain closed externally (outbound 443 Arc-only mode)." -ForegroundColor Green
}

Write-Host "`nStep 1 complete. Proceed to .\onprem\2-setup-database.ps1." -ForegroundColor Green
