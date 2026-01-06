<#
.SYNOPSIS
    Tests SRE Agent queries against the demo environment.

.DESCRIPTION
    Validates that the demo environment is properly configured by running
    sample queries that the SRE Agent would use.

.PARAMETER ResourceGroupName
    Name of the resource group. Default: infra-sre-demo-rg

.PARAMETER Scenario
    Which scenario to test: vm-metrics, backup-failures, service-health, all

.EXAMPLE
    ./test-queries.ps1 -Scenario all

.EXAMPLE
    ./test-queries.ps1 -Scenario vm-metrics
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = "infra-sre-demo-rg",

    [Parameter(Mandatory = $false)]
    [ValidateSet("vm-metrics", "backup-failures", "service-health", "all")]
    [string]$Scenario = "all"
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

function Write-Warning {
    param([string]$Message)
    Write-Host "⚠ $Message" -ForegroundColor Yellow
}

function Write-Info {
    param([string]$Message)
    Write-Host "ℹ $Message" -ForegroundColor Gray
}

# =============================================================================
# Get Resource Information
# =============================================================================

Write-Step "Gathering Resource Information"

$workspaceName = "log-analytics-sre-demo"
$workspaceId = az monitor log-analytics workspace show `
    -g $ResourceGroupName -n $workspaceName `
    --query customerId -o tsv 2>$null

if (-not $workspaceId) {
    Write-Error "Log Analytics workspace not found. Please run deploy.ps1 first."
}
Write-Success "Log Analytics Workspace: $workspaceName"

$rsvName = az backup vault list -g $ResourceGroupName --query "[0].name" -o tsv 2>$null
Write-Success "Recovery Vault: $rsvName"

# =============================================================================
# Test VM Metrics Queries
# =============================================================================

if ($Scenario -eq "vm-metrics" -or $Scenario -eq "all") {
    Write-Step "Testing VM Metrics Queries"
    
    # Test CPU metrics
    Write-Info "Checking for CPU performance data..."
    $cpuQuery = @"
Perf
| where TimeGenerated > ago(1h)
| where ObjectName == 'Processor' and CounterName == '% Processor Time'
| summarize count() by Computer
| project Computer, DataPoints=count_
"@
    
    $cpuResult = az monitor log-analytics query `
        -w $workspaceId `
        --analytics-query $cpuQuery `
        --output json 2>$null | ConvertFrom-Json
    
    if ($cpuResult.tables[0].rows.Count -gt 0) {
        Write-Success "CPU metrics found for $($cpuResult.tables[0].rows.Count) VM(s)"
        foreach ($row in $cpuResult.tables[0].rows) {
            Write-Info "  $($row[0]): $($row[1]) data points"
        }
    } else {
        Write-Warning "No CPU metrics found. Azure Monitor Agent may need more time to collect data."
    }
    
    # Test Memory metrics
    Write-Info "`nChecking for memory performance data..."
    $memQuery = @"
Perf
| where TimeGenerated > ago(1h)
| where CounterName == 'Available MBytes Memory' or CounterName == 'Available MBytes'
| summarize count() by Computer
"@
    
    $memResult = az monitor log-analytics query `
        -w $workspaceId `
        --analytics-query $memQuery `
        --output json 2>$null | ConvertFrom-Json
    
    if ($memResult.tables[0].rows.Count -gt 0) {
        Write-Success "Memory metrics found for $($memResult.tables[0].rows.Count) VM(s)"
    } else {
        Write-Warning "No memory metrics found."
    }
    
    # Test for anomalies
    Write-Info "`nChecking for detected anomalies..."
    $anomalyQuery = @"
Perf
| where TimeGenerated > ago(24h)
| where 
    (ObjectName == 'Processor' and CounterName == '% Processor Time' and CounterValue > 90)
    or (CounterName in ('Available MBytes Memory', 'Available MBytes') and CounterValue < 500)
    or (CounterName == 'Disk Transfers/sec' and CounterValue > 500)
| summarize AnomalyCount = count() by Computer
"@
    
    $anomalyResult = az monitor log-analytics query `
        -w $workspaceId `
        --analytics-query $anomalyQuery `
        --output json 2>$null | ConvertFrom-Json
    
    if ($anomalyResult.tables[0].rows.Count -gt 0) {
        Write-Success "Anomalies detected!"
        foreach ($row in $anomalyResult.tables[0].rows) {
            Write-Info "  $($row[0]): $($row[1]) anomaly events"
        }
    } else {
        Write-Info "No anomalies detected in last 24 hours. Run generate-problems.ps1 to create some."
    }
}

# =============================================================================
# Test Backup Queries
# =============================================================================

if ($Scenario -eq "backup-failures" -or $Scenario -eq "all") {
    Write-Step "Testing Backup Queries"
    
    if ($rsvName) {
        # List all backup jobs
        Write-Info "Checking backup job status..."
        $jobs = az backup job list `
            -g $ResourceGroupName `
            --vault-name $rsvName `
            --query "[].{Status:properties.status, VM:properties.entityFriendlyName}" `
            -o json 2>$null | ConvertFrom-Json
        
        if ($jobs.Count -gt 0) {
            $failed = ($jobs | Where-Object { $_.Status -eq "Failed" }).Count
            $completed = ($jobs | Where-Object { $_.Status -eq "Completed" }).Count
            $inProgress = ($jobs | Where-Object { $_.Status -eq "InProgress" }).Count
            
            Write-Success "Found $($jobs.Count) backup job(s)"
            Write-Info "  Completed: $completed"
            Write-Info "  Failed: $failed"
            Write-Info "  In Progress: $inProgress"
            
            if ($failed -gt 0) {
                Write-Success "Backup failures detected - ready for SRE Agent demo!"
            }
        } else {
            Write-Warning "No backup jobs found. Backups may not have run yet."
        }
        
        # Check protected items
        Write-Info "`nChecking protected VMs..."
        $items = az backup item list `
            -g $ResourceGroupName `
            --vault-name $rsvName `
            --backup-management-type AzureIaasVM `
            --query "[].{Name:properties.friendlyName, Status:properties.lastBackupStatus}" `
            -o json 2>$null | ConvertFrom-Json
        
        if ($items.Count -gt 0) {
            Write-Success "Found $($items.Count) protected VM(s)"
            foreach ($item in $items) {
                Write-Info "  $($item.Name): $($item.Status)"
            }
        }
    } else {
        Write-Warning "Recovery Services Vault not found."
    }
}

# =============================================================================
# Test Service Health Queries
# =============================================================================

if ($Scenario -eq "service-health" -or $Scenario -eq "all") {
    Write-Step "Testing Service Health Queries"
    
    Write-Info "Checking for Service Health events..."
    
    # Note: Service Health events are actual Azure events, not simulated
    $healthEvents = az monitor activity-log list `
        --start-time ((Get-Date).AddDays(-30).ToString("yyyy-MM-ddTHH:mm:ssZ")) `
        --query "[?category.value=='ServiceHealth'].{Type:properties.incidentType, Title:properties.title}" `
        -o json 2>$null | ConvertFrom-Json
    
    if ($healthEvents.Count -gt 0) {
        Write-Success "Found $($healthEvents.Count) Service Health event(s) in last 30 days"
        $grouped = $healthEvents | Group-Object Type
        foreach ($group in $grouped) {
            Write-Info "  $($group.Name): $($group.Count) event(s)"
        }
    } else {
        Write-Info "No Service Health events in last 30 days (this is good - no outages!)"
    }
    
    # Check Service Health alert configuration
    Write-Info "`nChecking Service Health alert configuration..."
    $alerts = az monitor activity-log alert list `
        -g $ResourceGroupName `
        --query "[?contains(name, 'service-health')].name" `
        -o json 2>$null | ConvertFrom-Json
    
    if ($alerts.Count -gt 0) {
        Write-Success "Service Health alert configured: $($alerts -join ', ')"
    } else {
        Write-Warning "No Service Health alert found. Check deployment."
    }
}

# =============================================================================
# Summary
# =============================================================================

Write-Step "Test Summary"

Write-Host "`nEnvironment Status:" -ForegroundColor White
Write-Host "  Resource Group: $ResourceGroupName" -ForegroundColor Gray
Write-Host "  Log Analytics: $workspaceName" -ForegroundColor Gray
Write-Host "  Recovery Vault: $rsvName" -ForegroundColor Gray

Write-Host "`nSRE Agent can now:" -ForegroundColor White
Write-Host "  • Query VM metrics via Log Analytics (KQL)" -ForegroundColor Gray
Write-Host "  • Check backup status via Azure CLI" -ForegroundColor Gray
Write-Host "  • Monitor Service Health via Activity Log" -ForegroundColor Gray

Write-Host "`n"
