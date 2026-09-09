# Shared helpers for operating against the private AKS cluster from outside the VNet.
# Every kubectl operation in this repo goes through `az aks command invoke` so the
# scripts work identically against a private (locked-down) cluster — exactly the
# path the SRE Agent uses.
#
# Resilience note: when the AKS runCommand endpoint reports a non-standard
# terminal status (e.g. the temporary command pod can't schedule), the CLI's
# long-running-operation poller surfaces "Operation returned an invalid status
# 'OK'" instead of the underlying reason. See Azure/azure-cli#22870 for the
# same shape against a different trigger. We detect that error and fall back
# to a direct REST call against the same runCommand endpoint, which lets us
# read the actual `properties.reason` (e.g. "Unschedulable - Insufficient
# memory") and report something useful to the operator.

function Invoke-AksCommandViaRest {
    <#
    .SYNOPSIS
      Direct REST call to the AKS runCommand endpoint, bypassing the CLI poller.
    #>
    param(
        [Parameter(Mandatory)] [string]$ResourceGroup,
        [Parameter(Mandatory)] [string]$ClusterName,
        [Parameter(Mandatory)] [string]$Command,
        [string[]]$Files = @(),
        [int]$TimeoutSeconds = 300
    )

    if ($Files.Count -gt 0) {
        # File upload is non-trivial over REST (multipart). Caller should fall
        # back to the CLI for this path; we only handle plain commands here.
        throw "Invoke-AksCommandViaRest does not support file uploads. Re-run with az CLI working."
    }

    $sub = (az account show --query id -o tsv 2>$null).Trim()
    if (-not $sub) { throw "Not logged in to az. Run 'az login'." }

    # ARM token for management.azure.com
    $armToken = (az account get-access-token --resource "https://management.core.windows.net/" --query accessToken -o tsv 2>$null).Trim()
    if (-not $armToken) { throw "Failed to acquire ARM access token." }

    # Cluster token (audience = AKS first-party server app). Required for AAD-enabled clusters.
    $clusterToken = (az account get-access-token --resource "6dae42f8-4368-4678-94ff-3960e28e3630" --query accessToken -o tsv 2>$null).Trim()
    if (-not $clusterToken) { throw "Failed to acquire AKS cluster token." }

    $body = @{ command = $Command; clusterToken = $clusterToken } | ConvertTo-Json -Compress
    $uri = "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.ContainerService/managedClusters/$ClusterName/runCommand?api-version=2024-09-01"
    $headers = @{ Authorization = "Bearer $armToken"; 'Content-Type' = 'application/json' }

    $resp = Invoke-WebRequest -Method Post -Uri $uri -Headers $headers -Body $body -SkipHttpErrorCheck
    if ($resp.StatusCode -ne 202) {
        return [pscustomobject]@{ exitCode = 1; logs = "runCommand POST failed: HTTP $($resp.StatusCode) $($resp.Content)" }
    }

    $loc = $resp.Headers.Location
    if ($loc -is [array]) { $loc = $loc[0] }
    if (-not $loc) {
        return [pscustomobject]@{ exitCode = 1; logs = 'runCommand returned no Location header' }
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $r = Invoke-WebRequest -Method Get -Uri $loc -Headers @{ Authorization = "Bearer $armToken" } -SkipHttpErrorCheck
        if ($r.StatusCode -eq 202) { continue }
        if ($r.StatusCode -ne 200) {
            return [pscustomobject]@{ exitCode = 1; logs = "commandResults poll: HTTP $($r.StatusCode) $($r.Content)" }
        }
        try { $obj = $r.Content | ConvertFrom-Json } catch {
            return [pscustomobject]@{ exitCode = 1; logs = $r.Content }
        }
        $state = $obj.properties.provisioningState
        if ($state -eq 'Succeeded') {
            return [pscustomobject]@{ exitCode = [int]($obj.properties.exitCode); logs = [string]$obj.properties.logs }
        }
        if ($state -in @('Failed', 'Canceled')) {
            $reason = $obj.properties.reason
            if (-not $reason) { $reason = $obj.properties.logs }
            return [pscustomobject]@{ exitCode = 1; logs = "runCommand $state`: $reason" }
        }
        # else: still running — poll again
    }
    return [pscustomobject]@{ exitCode = 124; logs = "runCommand timed out after $TimeoutSeconds s" }
}

function Invoke-AksCommand {
    <#
    .SYNOPSIS
      Run a shell/kubectl command inside the private AKS cluster via ARM.

    .DESCRIPTION
      Wraps `az aks command invoke`. Azure spins up a temporary pod inside the
      cluster network (cluster-admin KubeConfig auto-injected), executes the
      command, and returns logs + exitCode. Works identically against a
      private cluster — no VPN, no jumpbox, no public endpoint.

      Auto-falls back to a direct REST call when the CLI surfaces
      "Operation returned an invalid status 'OK'" — typically caused by
      the temp command pod failing to schedule (cluster sizing). The REST
      path can read the actual reason from the response body.

    .PARAMETER Files
      Local file or directory paths to upload to /workdir/ in the temp pod.
      kubectl can then reference them by basename (or use `kubectl apply -f .`).
      File uploads always use the CLI path (REST fallback can't multipart).

    .PARAMETER Quiet
      Suppress the streaming logs print on success.
    #>
    param(
        [Parameter(Mandatory)] [string]$ResourceGroup,
        [Parameter(Mandatory)] [string]$ClusterName,
        [Parameter(Mandatory)] [string]$Command,
        [string[]]$Files = @(),
        [switch]$Quiet
    )

    $azArgs = @('aks', 'command', 'invoke',
                '-g', $ResourceGroup, '-n', $ClusterName,
                '--command', $Command,
                '-o', 'json')
    if ($Files.Count -gt 0) {
        foreach ($f in $Files) {
            $azArgs += '--file'
            $azArgs += $f
        }
    }

    $resultJson = & az @azArgs 2>&1 | Out-String
    $cliExit = $LASTEXITCODE

    if ($cliExit -ne 0) {
        # Detect the "invalid status 'OK'" poller edge case and fall back to REST
        # (when no files — REST path doesn't multipart). REST can surface the
        # actual `properties.reason` from the runCommand response.
        $isPollerEdge = $resultJson -match "Operation returned an invalid status 'OK'"
        if ($isPollerEdge -and $Files.Count -eq 0) {
            Write-Host "Falling back to direct runCommand REST to retrieve actual failure reason..." -ForegroundColor DarkYellow
            $result = Invoke-AksCommandViaRest -ResourceGroup $ResourceGroup -ClusterName $ClusterName -Command $Command
            if ($result.exitCode -ne 0) {
                Write-Host "Cluster command exited $($result.exitCode):" -ForegroundColor Yellow
                Write-Host $result.logs -ForegroundColor DarkGray
            } elseif (-not $Quiet -and $result.logs) {
                Write-Host $result.logs -ForegroundColor DarkGray
            }
            return $result
        }
        Write-Host "az aks command invoke failed (exit $cliExit):" -ForegroundColor Red
        Write-Host $resultJson -ForegroundColor DarkGray
        return [pscustomobject]@{ exitCode = $cliExit; logs = $resultJson }
    }

    try {
        $result = $resultJson | ConvertFrom-Json
    } catch {
        Write-Host "Could not parse az output as JSON:" -ForegroundColor Yellow
        Write-Host $resultJson -ForegroundColor DarkGray
        return [pscustomobject]@{ exitCode = 1; logs = $resultJson }
    }

    if ($result.exitCode -ne 0) {
        Write-Host "Cluster command exited $($result.exitCode):" -ForegroundColor Yellow
        Write-Host $result.logs -ForegroundColor DarkGray
    } elseif (-not $Quiet -and $result.logs) {
        Write-Host $result.logs -ForegroundColor DarkGray
    }
    return $result
}

function Assert-ZavaRequestTelemetry {
    param([Parameter(Mandatory)][string]$ResourceGroup)

    $workspace = az monitor log-analytics workspace list -g $ResourceGroup --query '[0].customerId' -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($workspace)) {
        throw "Could not resolve the Log Analytics workspace in $ResourceGroup. No fault was injected."
    }
    $query = "AppRequests | where TimeGenerated > ago(10m) | where AppRoleName == 'zava-api' | summarize n=count()"
    $raw = az monitor log-analytics query -w $workspace --analytics-query $query -o json --only-show-errors 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "Telemetry query failed; request count is unknown. No fault was injected. $($raw.Trim())"
    }
    $rows = @(ConvertFrom-Json -InputObject $raw -ErrorAction Stop)
    $count = 0L
    if ($rows.Count -ne 1 -or -not $rows[0].PSObject.Properties['n'] -or
        -not [long]::TryParse([string]$rows[0].n, [ref]$count) -or $count -lt 0) {
        throw 'Telemetry query returned an invalid request count. No fault was injected.'
    }
    if ($count -eq 0) {
        throw 'No AppRequests from zava-api were found in the last 10 minutes. Verify ingestion before injecting a fault; use -SkipTelemetryCheck only when an empty workspace is intentional.'
    }
    Write-Host "Telemetry OK ($count AppRequests in last 10 min)." -ForegroundColor Green
}

function Assert-AksCommandSucceeded {
    param([object]$Result, [string]$Operation)
    if (-not $Result -or $Result.exitCode -ne 0) {
        $details = if ($Result) { $Result.logs } else { 'No command result returned.' }
        throw "${Operation} failed: $details"
    }
}

function Wait-AksOperatorAccess {
    param([string]$ResourceGroup, [string]$ClusterName, [string]$Namespace = 'zava-demo', [int]$MaxAttempts = 30, [int]$DelaySeconds = 10)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        # A version check succeeds without the permissions needed to deploy.
        $result = Invoke-AksCommand -ResourceGroup $ResourceGroup -ClusterName $ClusterName `
            -Command "kubectl get namespaces -o name >/dev/null && kubectl auth can-i create deployments.apps -n $Namespace" -Quiet
        if ($result -and $result.exitCode -eq 0 -and $result.logs.Trim() -eq 'yes') { return }
        if ($attempt -lt $MaxAttempts) {
            Write-Host "  Waiting for AKS operator access ($attempt/$MaxAttempts)..." -ForegroundColor DarkGray
            Start-Sleep -Seconds $DelaySeconds
        }
    }
    throw "AKS operator access did not become ready. Verify the operator's AKS RBAC Cluster Admin assignment on $ClusterName before retrying."
}

function Wait-AksIngressAddress {
    param(
        [string]$ResourceGroup,
        [string]$ClusterName,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300,
        [ValidateRange(0, 60)][int]$PollSeconds = 10
    )
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Write-Host "  Waiting for the ingress public IP (up to $TimeoutSeconds seconds)..." -ForegroundColor DarkGray
    while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $result = Invoke-AksCommand -ResourceGroup $ResourceGroup -ClusterName $ClusterName `
            -Command "kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}'" -Quiet
        Assert-AksCommandSucceeded $result 'Public endpoint lookup'
        $address = ([string]$result.logs).Trim()
        if ($address -and $address -notin @('pending', '<pending>')) {
            $parsedAddress = $null
            if ($address -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or
                -not [Net.IPAddress]::TryParse($address, [ref]$parsedAddress)) {
                throw "Public endpoint lookup returned an invalid IPv4 address: $address"
            }
            return $address
        }
        $remaining = $TimeoutSeconds - $clock.Elapsed.TotalSeconds
        if ($remaining -gt 0 -and $PollSeconds -gt 0) {
            Start-Sleep -Milliseconds ([int](1000 * [Math]::Min($PollSeconds, $remaining)))
        }
    }
    throw "Ingress public IP was not assigned within $TimeoutSeconds seconds. Inspect service ingress-nginx/ingress-nginx-controller on $ClusterName and retry post-provision; agent configuration has not run."
}

function Resolve-AksContext {
    <#
    .SYNOPSIS
      Find the resource group and AKS cluster name from azd env / azd-injected
      env vars / fallbacks.
    #>
    param(
        [string]$ResourceGroup = "",
        [string]$ClusterName = ""
    )
    # 1. Honor caller args first
    # 2. Try azd-injected env vars (set in azd hook subprocesses)
    if (-not $ResourceGroup) { $ResourceGroup = [Environment]::GetEnvironmentVariable("RESOURCE_GROUP") }
    if (-not $ClusterName)   { $ClusterName   = [Environment]::GetEnvironmentVariable("AKS_CLUSTER_NAME") }
    # 3. Fall back to `azd env get-value`
    if (-not $ResourceGroup) {
        try { $ResourceGroup = (azd env get-value RESOURCE_GROUP 2>$null).Trim() } catch {}
    }
    if (-not $ClusterName) {
        try { $ClusterName = (azd env get-value AKS_CLUSTER_NAME 2>$null).Trim() } catch {}
    }
    # 4. No fallback — fail loud. The only paths that work are: (a) caller
    #    passed the params explicitly, (b) azd-injected env vars, or (c)
    #    `azd env get-value`. If none of those resolved, hardcoding a guess
    #    just hides the real problem (azd not installed, wrong env selected,
    #    stale shell). Surface it.
    if (-not $ResourceGroup) {
        throw "Could not resolve RESOURCE_GROUP. Pass -ResourceGroup explicitly, set the env var, or run inside an azd env (azd env select <name>)."
    }
    if (-not $ClusterName) {
        $ClusterName = (az aks list -g $ResourceGroup --query '[0].name' -o tsv 2>$null)
        if (-not $ClusterName) {
            throw "Could not find an AKS cluster in resource group '$ResourceGroup'. Pass -ClusterName explicitly or verify the resource group."
        }
    }
    return [pscustomobject]@{ ResourceGroup = $ResourceGroup; ClusterName = $ClusterName }
}

function Reset-DemoAlertRule {
    <#
    .SYNOPSIS
      Makes a stateful Azure Monitor alert rule ready for another demo run.

    .DESCRIPTION
      Agent-side response-plan merging is disabled, but Azure Monitor still keeps
      one stateful alert instance per rule. A prior instance that remains Fired
      prevents a new activation and therefore prevents a fresh agent dispatch.
      This helper fails before fault injection if the old condition is still
      active, and closes a resolved instance so the next activation is New.
    #>
    param(
        [Parameter(Mandatory)] [string]$ResourceGroup,
        [Parameter(Mandatory)] [string]$AlertRuleName
    )

    $sub = (az account show --query id -o tsv 2>$null).Trim()
    if (-not $sub) { throw "Not logged in to az. Run 'az login'." }
    $token = (az account get-access-token --resource 'https://management.azure.com/' --query accessToken -o tsv 2>$null).Trim()
    if (-not $token) { throw "Could not acquire an Azure Resource Manager token. Run 'az login'." }
    $headers = @{ Authorization = "Bearer $token" }

    $url = "https://management.azure.com/subscriptions/$sub/providers/Microsoft.AlertsManagement/alerts?api-version=2019-05-05-preview&timeRange=30d&pageCount=250"
    $response = Invoke-RestMethod -Method Get -Uri $url -Headers $headers
    $alerts = @($response.value | Where-Object {
        $essentials = $_.properties.essentials
        $rule = [string]$essentials.alertRule
        $ruleName = if ($rule.Contains('/')) { $rule.Split('/')[-1] } else { $rule }
        $essentials.targetResourceGroup -eq $ResourceGroup -and $ruleName -eq $AlertRuleName
    } | Sort-Object { [datetime]$_.properties.essentials.startDateTime } -Descending)

    if ($alerts.Count -eq 0) {
        Write-Host "Alert preflight: no prior $AlertRuleName instance." -ForegroundColor DarkGray
        return
    }

    $latest = $alerts[0]
    $essentials = $latest.properties.essentials
    if ($essentials.monitorCondition -eq 'Fired') {
        throw "Alert preflight: prior '$AlertRuleName' condition is still Fired. Restore the previous fault and wait for Azure Monitor to report Resolved before starting another run; otherwise no fresh agent dispatch is possible."
    }

    if ($essentials.alertState -ne 'Closed') {
        $alertId = [string]$latest.id
        $changeStateUrl = "https://management.azure.com${alertId}/changestate?api-version=2018-05-05&newState=Closed"
        try {
            Invoke-RestMethod -Method Post -Uri $changeStateUrl -Headers $headers | Out-Null
        } catch {
            throw "Could not close prior '$AlertRuleName' alert instance."
        }
        Write-Host "Alert preflight: closed prior resolved $AlertRuleName instance." -ForegroundColor DarkGray
    } else {
        Write-Host "Alert preflight: prior $AlertRuleName instance is resolved and closed." -ForegroundColor DarkGray
    }
}
