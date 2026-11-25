<#
.SYNOPSIS
    Step 2 (On-Prem Windows Server): Creates CaldovaExpenseDb, seeds baseline data, and grants
    Windows Integrated Auth (db_datareader, db_datawriter, EXECUTE) to IIS APPPOOL\CaldovaExpensePool.

.DESCRIPTION
    Uses built-in .NET SqlClient so no external SqlServer PowerShell module or sqlcmd install is required.
    Zero SQL passwords are created or stored.

.EXAMPLE
    .\onprem\2-setup-database.ps1
    .\onprem\2-setup-database.ps1 -SqlServerInstance "localhost\SQLEXPRESS"
#>
[CmdletBinding()]
param(
    [string] $SqlServerInstance = "",
    [string] $AppPoolName = "CaldovaExpensePool",
    [string] $SqlScriptPath = ""
)

$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    throw "Run 2-setup-database.ps1 from an Administrator PowerShell session."
}

if (-not $SqlScriptPath) {
    $candidateRepo = Join-Path (Split-Path -Parent $PSScriptRoot) "sql\init-caldova-expense.sql"
    $candidateDeployed = "C:\inetpub\caldova-expense\_deploy\init-caldova-expense.sql"
    if (Test-Path $candidateRepo) {
        $SqlScriptPath = $candidateRepo
    }
    elseif (Test-Path $candidateDeployed) {
        $SqlScriptPath = $candidateDeployed
    }
    else {
        throw "Could not find init-caldova-expense.sql. Pass -SqlScriptPath explicitly."
    }
}

# Ensure IIS AppPool exists before mapping [IIS APPPOOL\CaldovaExpensePool] in SQL Server
if (Get-Module -ListAvailable -Name WebAdministration) {
    Import-Module WebAdministration
    if (-not (Test-Path "IIS:\AppPools\$AppPoolName")) {
        New-WebAppPool -Name $AppPoolName | Out-Null
        Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name "managedRuntimeVersion" -Value ""
    }
}

function Test-SqlEndpoint([string] $ServerName) {
    $cs = "Server=$ServerName;Database=master;Integrated Security=True;Encrypt=False;TrustServerCertificate=True;Connect Timeout=4;"
    $conn = New-Object System.Data.SqlClient.SqlConnection($cs)
    try {
        $conn.Open()
        return $true
    }
    catch {
        return $false
    }
    finally {
        $conn.Dispose()
    }
}

if (-not $SqlServerInstance) {
    foreach ($candidate in @("localhost,1433", "localhost", "localhost\SQLEXPRESS", "(local)")) {
        if (Test-SqlEndpoint -ServerName $candidate) {
            $SqlServerInstance = $candidate
            break
        }
    }
}

if (-not $SqlServerInstance -or -not (Test-SqlEndpoint -ServerName $SqlServerInstance)) {
    throw "Could not connect to local SQL Server via Windows Integrated Auth. Verify MSSQLSERVER or MSSQL`$SQLEXPRESS is running and your account is a SQL sysadmin."
}

Write-Host "Connected to SQL Server instance: $SqlServerInstance" -ForegroundColor Cyan

# Persist detected SQL instance so Step 3 configures appsettings.Production.json automatically
$stateDir = "C:\ProgramData\CaldovaExpense"
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
Set-Content -Path (Join-Path $stateDir "sql-instance.txt") -Value $SqlServerInstance -NoNewline -Encoding utf8

# Split on GO batch separators and execute against SQL Server
$rawSql = Get-Content -Path $SqlScriptPath -Raw
if ($AppPoolName -ne "CaldovaExpensePool") {
    $rawSql = $rawSql.Replace("IIS APPPOOL\CaldovaExpensePool", "IIS APPPOOL\$AppPoolName")
}

$batches = [System.Text.RegularExpressions.Regex]::Split($rawSql, "^\s*GO\s*$", [System.Text.RegularExpressions.RegexOptions]::Multiline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

$connStr = "Server=$SqlServerInstance;Database=master;Integrated Security=True;Encrypt=False;TrustServerCertificate=True;Connect Timeout=10;"
$conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
$conn.Add_InfoMessage({ param($s, $e) Write-Host "  [SQL] $($e.Message)" -ForegroundColor Gray })
$conn.Open()

try {
    foreach ($batch in $batches) {
        $trimmed = $batch.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        $cmd = $conn.CreateCommand()
        $cmd.CommandTimeout = 30
        $cmd.CommandText = $trimmed
        [void]$cmd.ExecuteNonQuery()
        $cmd.Dispose()
    }
}
finally {
    $conn.Dispose()
}

# Verify row count in CaldovaExpenseDb
$verifyConn = New-Object System.Data.SqlClient.SqlConnection("Server=$SqlServerInstance;Database=CaldovaExpenseDb;Integrated Security=True;Encrypt=False;TrustServerCertificate=True;")
$verifyConn.Open()
try {
    $verifyCmd = $verifyConn.CreateCommand()
    $verifyCmd.CommandText = "SELECT COUNT(*) FROM dbo.ExpenseReports;"
    $count = [int]$verifyCmd.ExecuteScalar()
    Write-Host "CaldovaExpenseDb initialized ($count seeded expense report rows)." -ForegroundColor Green
}
finally {
    $verifyConn.Dispose()
}

Write-Host "`nStep 2 complete. Proceed to .\onprem\3-deploy-caldova-expense.ps1." -ForegroundColor Green
