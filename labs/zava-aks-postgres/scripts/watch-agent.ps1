#Requires -Version 7.4
<#
.SYNOPSIS
    Watch the SRE Agent's incident threads via the data-plane API.

.DESCRIPTION
    Calls the agent's `https://<endpoint>.azuresre.ai/api/v1/threads` endpoint
    (and `/threads/{id}/messages` for a specific incident) using the same
    `https://azuresre.dev` Entra token the portal uses. This is the easy way
    to see what the agent is actually doing during a break/fix demo without
    bouncing into the portal.

    The agent endpoint is read from the azd env var `SRE_AGENT_ENDPOINT`.

.PARAMETER List
    List all incident threads with status, created time, and title.
    (Default action when no parameters are given.)

.PARAMETER Tail
    Tail the messages of the most recently created thread that matches
    `-Title` (substring, case-insensitive). Polls every `-Interval` seconds
    and prints any new messages.

.PARAMETER Title
    Substring filter for `-Tail` and `-Show`. E.g. "network", "stopped",
    "slow". Use the Sev tag (e.g. "Sev1") to be more specific.

.PARAMETER Show
    Print all messages for the most recent matching thread once and exit.

.PARAMETER Interval
    Seconds between polls when tailing. Default 30.

.EXAMPLE
    .\scripts\watch-agent.ps1
    # Lists all threads.

.EXAMPLE
    .\scripts\watch-agent.ps1 -Tail -Title network
    # Live-follows the network-blocked incident.

.EXAMPLE
    .\scripts\watch-agent.ps1 -Show -Title slow
    # Dumps the slow-query incident transcript once.
#>
param(
    [switch]$List,
    [switch]$Tail,
    [switch]$Show,
    [string]$Title,
    [int]$Interval = 30
)

$ErrorActionPreference = "Stop"

function Get-AgentEndpoint {
    $ep = [Environment]::GetEnvironmentVariable("SRE_AGENT_ENDPOINT")
    if (-not $ep) {
        try { $ep = (azd env get-value SRE_AGENT_ENDPOINT 2>$null).Trim() } catch {}
    }
    if (-not $ep -or $ep -notmatch '^https://') {
        Write-Error "SRE_AGENT_ENDPOINT not set. Run from azd env or `azd env get-value SRE_AGENT_ENDPOINT` first."
        exit 1
    }
    return $ep
}

function Get-AgentHeaders {
    $token = az account get-access-token --resource "https://azuresre.dev" --query accessToken -o tsv 2>$null
    if (-not $token) { Write-Error "Could not get token. Run 'az login' first."; exit 1 }
    return @{ Authorization = "Bearer $token"; Accept = "application/json" }
}

function Get-Threads {
    $ep = Get-AgentEndpoint
    $headers = Get-AgentHeaders
    $r = Invoke-RestMethod -Uri "$ep/api/v1/threads" -Headers $headers -MaximumRedirection 5 -AllowInsecureRedirect
    $arr = if ($r.value) { $r.value } else { $r }
    return $arr | Sort-Object { [DateTime]$_.createdTimestamp }
}

function Get-ThreadMessages {
    param([string]$ThreadId)
    $ep = Get-AgentEndpoint
    $headers = Get-AgentHeaders
    $r = Invoke-RestMethod -Uri "$ep/api/v1/threads/$ThreadId/messages" -Headers $headers -MaximumRedirection 5 -AllowInsecureRedirect
    $arr = if ($r.value) { $r.value } else { $r }
    return $arr | Sort-Object { [DateTime]$_.timeStamp }
}

function Find-Thread {
    param([string]$Filter)
    $threads = Get-Threads
    if (-not $Filter) { return $threads | Select-Object -Last 1 }
    $matches = $threads | Where-Object { $_.title -match [regex]::Escape($Filter) }
    if (-not $matches) { Write-Error "No thread matches '$Filter'"; return $null }
    return $matches | Select-Object -Last 1
}

function Format-Message {
    param($Msg)
    $author = if ($Msg.author) { $Msg.author.role } else { '?' }
    $ts = ([DateTime]$Msg.timeStamp).ToUniversalTime().ToString('HH:mm:ss')
    $txt = if ($Msg.text) {
        ($Msg.text -replace '\s+', ' ').Trim()
    } elseif ($Msg.azCliExecution) {
        "az: $($Msg.azCliExecution.command)"
    } elseif ($Msg.kubectlExecution) {
        "kubectl: $($Msg.kubectlExecution.command)"
    } elseif ($Msg.psqlExecution) {
        "psql: $($Msg.psqlExecution.query)"
    } elseif ($Msg.terminalResult) {
        "term: $($Msg.terminalResult.command)"
    } elseif ($Msg.mcpToolExecution) {
        "mcp: $($Msg.mcpToolExecution.toolName)"
    } else {
        "<$($Msg.messageType)>"
    }
    if ($txt.Length -gt 280) { $txt = $txt.Substring(0, 280) + '...' }
    return "[$ts] {0,-9} {1}" -f $author, $txt
}

function Show-List {
    $threads = Get-Threads
    "{0,-22} {1,-12} {2,-12} {3}" -f 'Created (UTC)', 'Status', 'Actions', 'Title'
    "{0,-22} {1,-12} {2,-12} {3}" -f '------------', '------', '-------', '-----'
    foreach ($t in $threads) {
        $created = ([DateTime]$t.createdTimestamp).ToUniversalTime().ToString('MM-dd HH:mm:ss')
        $iStat = if ($t.status.incidentStatus.status) { $t.status.incidentStatus.status } else { '?' }
        $aStat = if ($t.status.actionsStatus.hasCriticalActions) { 'critical' }
                 elseif ($t.status.actionsStatus.hasWarningActions) { 'warning' }
                 else { 'ok' }
        "{0,-22} {1,-12} {2,-12} {3}" -f $created, $iStat, $aStat, $t.title
    }
}

function Show-Thread {
    param([string]$Filter)
    $t = Find-Thread -Filter $Filter
    if (-not $t) { return }
    "=== Thread: $($t.title) (id: $($t.id), status: $($t.status.incidentStatus.status)) ==="
    $msgs = Get-ThreadMessages -ThreadId $t.id
    foreach ($m in $msgs) { Format-Message -Msg $m }
    "`n=== $($msgs.Count) total messages ==="
}

function Tail-Thread {
    param([string]$Filter, [int]$Interval)
    $t = Find-Thread -Filter $Filter
    if (-not $t) { return }
    "=== Tailing: $($t.title) (id: $($t.id)) — Ctrl+C to stop ==="
    $seen = @{}
    while ($true) {
        try {
            $msgs = Get-ThreadMessages -ThreadId $t.id
            foreach ($m in $msgs) {
                if (-not $seen.ContainsKey($m.id)) {
                    Format-Message -Msg $m
                    $seen[$m.id] = $true
                }
            }
            # Refresh thread status occasionally
            $cur = Get-Threads | Where-Object { $_.id -eq $t.id }
            if ($cur -and $cur.status.incidentStatus.status -in @('resolved','closed','mitigated')) {
                "=== Incident reached terminal status: $($cur.status.incidentStatus.status) ==="
                break
            }
        } catch {
            "[tail error] $($_.Exception.Message)"
        }
        Start-Sleep -Seconds $Interval
    }
}

if ($Tail) { Tail-Thread -Filter $Title -Interval $Interval }
elseif ($Show) { Show-Thread -Filter $Title }
else { Show-List }
