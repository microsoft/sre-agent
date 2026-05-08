# Telemetry.ps1 — anonymous usage tracking for recipe popularity.
#
# Sends a single custom event to App Insights. Non-blocking, best-effort.
# No PII is collected — only recipe name, action, region, and OS.
#
# Opt out: set $env:SRE_AGENT_NO_TELEMETRY=1 or pass -NoTelemetry to any script.
#
# Usage (dot-sourced by other scripts):
#   . "$PSScriptRoot\Telemetry.ps1"
#   Send-Telemetry -Action "new-agent" -Recipe "azmon-lawappinsights" -Region "eastus2"

$script:TelemetryIKey = "f10eff7f-b995-4c41-8347-90f0f55d5969"
$script:TelemetryEndpoint = "https://eastus2-3.in.applicationinsights.azure.com/v2/track"

function Send-Telemetry {
    param(
        [string]$Action = "unknown",
        [string]$Recipe = "unknown",
        [string]$Region = "unknown"
    )

    # Skip if opted out
    if ($env:SRE_AGENT_NO_TELEMETRY -eq "1") { return }
    if ((Test-Path variable:script:NoTelemetry) -and $script:NoTelemetry) { return }

    $osType = if ($IsWindows) { "Windows" } elseif ($IsMacOS) { "Darwin" } else { "Linux" }

    $body = @"
[{
  "name": "Microsoft.ApplicationInsights.Event",
  "time": "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')",
  "iKey": "$($script:TelemetryIKey)",
  "data": {
    "baseType": "EventData",
    "baseData": {
      "name": "recipe-usage",
      "properties": {
        "action": "$Action",
        "recipe": "$Recipe",
        "region": "$Region",
        "os": "$osType"
      }
    }
  }
}]
"@

    # Fire and forget — never block or fail the main script
    try {
        $null = Start-Job -ScriptBlock {
            param($url, $payload)
            try { Invoke-RestMethod -Uri $url -Method Post -Body $payload -ContentType 'application/json' -TimeoutSec 5 } catch {}
        } -ArgumentList $script:TelemetryEndpoint, $body
    } catch {}
}
