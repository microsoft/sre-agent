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
