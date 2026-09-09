#Requires -Version 7.4

function Test-ZavaTransientArmError {
    param([object]$ErrorDetail)
    if (-not $ErrorDetail) { return $false }
    $details = $ErrorDetail.PSObject.Properties['details']
    if ($details -and $null -ne $details.Value -and @($details.Value).Count -gt 0) {
        foreach ($child in $details.Value) {
            if (-not (Test-ZavaTransientArmError $child)) { return $false }
        }
        return $true
    }
    return $ErrorDetail.PSObject.Properties['code'] -and
        $ErrorDetail.code -in @('BadGateway', 'ServiceUnavailable', 'GatewayTimeout', 'TooManyRequests', 'InternalServerError')
}

function Get-ZavaArmConnectors {
    param([string]$AgentArmId)
    $response = Invoke-ZavaArmRequest -Path "$AgentArmId/connectors?api-version=2025-05-01-preview"
    if ($response.StatusCode -ne 200 -or -not $response.Body -or
        -not $response.Body.PSObject.Properties['value'] -or $response.Body.value -isnot [array]) {
        throw "Could not list ARM connectors (HTTP $($response.StatusCode))."
    }
    if ($response.Body.PSObject.Properties['nextLink'] -and $response.Body.nextLink) {
        throw 'Connector inventory is paginated; refusing a partial comparison.'
    }
    return @($response.Body.value | Sort-Object name)
}

function Get-ZavaConnectorPlan {
    param([string]$ConfigRoot, [object[]]$Existing, [switch]$UpdateExisting)
    $definitions = (Get-Content -Raw (Join-Path $ConfigRoot 'agent-config.json') | ConvertFrom-Json).connectors
    if ($definitions -isnot [array] -or $definitions.Count -eq 0) { throw 'Manifest connectors must be a nonempty array.' }
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $tags = @{}
    $differences = [Collections.Generic.List[string]]::new()
    foreach ($connector in $definitions) {
        if ($connector.name -cnotmatch '^[a-z0-9][a-z0-9-]*$' -or -not $names.Add($connector.name)) {
            throw "Invalid or duplicate connector name: $($connector.name)"
        }
        $matches = @($Existing | Where-Object { $_.name -eq $connector.name })
        if ($matches.Count -gt 1) { throw "Duplicate connector name: $($connector.name)" }
        if ($matches.Count) {
            $actual = $matches[0]
            if ($actual.name -cne $connector.name) { throw "Connector name casing differs: $($actual.name)" }
            Compare-ExpectedProperties -Expected @{
                dataConnectorType = $connector.properties.dataConnectorType
                identity = $connector.properties.identity
            } -Actual $actual.properties -Path "connectors/$($connector.name)" -Differences $differences
            if ($actual.PSObject.Properties['tags'] -and $null -ne $actual.tags) {
                $tags[$connector.name] = $actual.tags
            }
        }
    }
    if ($differences.Count) {
        Write-Host ($differences -join "`n") -ForegroundColor Yellow
        if (-not $UpdateExisting) {
            throw 'Existing connector type or identity differs. Review it before using -UpdateExisting. Nothing has been written.'
        }
    }
    return [pscustomobject]@{ Definitions = @($definitions); Existing = @($Existing | Sort-Object name); Tags = $tags }
}

function Invoke-ZavaConnectorDeployment {
    param(
        [object]$Template,
        [hashtable]$Parameters,
        [string]$DeploymentPath,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 600,
        [ValidateRange(0, 60)][int]$PollSeconds = 5,
        [ValidateRange(1, 5)][int]$MaxAttempts = 3
    )
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $body = @{ properties = @{ mode = 'Incremental'; template = $Template; parameters = $Parameters } }
    $lastError = 'no deployment response'
    $mayBeRunning = $false
    $transientConnections = @(
        [Net.Http.HttpRequestError]::NameResolutionError,
        [Net.Http.HttpRequestError]::ConnectionError,
        [Net.Http.HttpRequestError]::ResponseEnded
    )
    try {
        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            $remaining = $TimeoutSeconds - $clock.Elapsed.TotalSeconds
            if ($remaining -le 0) { break }
            $submitted = $null
            try {
                $submitted = Invoke-ZavaArmRequest -Path "$DeploymentPath`?api-version=2022-09-01" -Method Put -Body $body `
                    -TimeoutSeconds ([Math]::Min(30, $remaining))
            } catch [OperationCanceledException] {
                $lastError = 'submission response timed out'
            } catch [Net.Http.HttpRequestException] {
                if ($_.Exception.HttpRequestError -notin $transientConnections) { throw }
                $lastError = "submission connection unavailable ($($_.Exception.HttpRequestError))"
            }
            if ($null -ne $submitted -and $submitted.StatusCode -notin @(200, 201, 202)) {
                if ($submitted.StatusCode -notin @(408, 429, 500, 502, 503, 504)) {
                    throw "Connector deployment submission failed with HTTP $($submitted.StatusCode): $($submitted.Text). Inspect $DeploymentPath."
                }
                $lastError = "submission HTTP $($submitted.StatusCode)"
            } else {
                # A lost submission response may still have started the deployment.
                $mayBeRunning = $true
                while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
                    $status = $null
                    $remaining = $TimeoutSeconds - $clock.Elapsed.TotalSeconds
                    if ($remaining -le 0) { break }
                    try {
                        $status = Invoke-ZavaArmRequest -Path "$DeploymentPath`?api-version=2022-09-01" `
                            -TimeoutSeconds ([Math]::Min(30, $remaining))
                    } catch [OperationCanceledException] {
                        $lastError = 'status request timed out'
                    } catch [Net.Http.HttpRequestException] {
                        if ($_.Exception.HttpRequestError -notin $transientConnections) { throw }
                        $lastError = "status connection unavailable ($($_.Exception.HttpRequestError))"
                    }
                    if ($null -ne $status) {
                        if ($status.StatusCode -eq 200) {
                            if (-not $status.Body -or -not $status.Body.PSObject.Properties['properties'] -or
                                -not $status.Body.properties.PSObject.Properties['provisioningState']) {
                                throw "Connector deployment response is missing provisioningState. Inspect $DeploymentPath before retrying."
                            }
                            $properties = $status.Body.properties
                            $lastError = "state $($properties.provisioningState)"
                            switch ($properties.provisioningState) {
                                'Succeeded' { $mayBeRunning = $false; return }
                                'Failed' {
                                    $mayBeRunning = $false
                                    $lastError = $properties.error | ConvertTo-Json -Depth 20 -Compress
                                    if (-not (Test-ZavaTransientArmError $properties.error)) {
                                        throw "Connector deployment failed: $lastError. Inspect $DeploymentPath."
                                    }
                                }
                                'Canceled' { $mayBeRunning = $false; throw "Connector deployment was canceled: $DeploymentPath" }
                            }
                            if ($properties.provisioningState -eq 'Failed') { break }
                        } else {
                            $lastError = "status HTTP $($status.StatusCode)"
                            if ($status.StatusCode -notin @(404, 408, 429, 500, 502, 503, 504)) {
                                throw "Connector deployment status failed with HTTP $($status.StatusCode). Inspect $DeploymentPath before retrying."
                            }
                        }
                    }
                    $remaining = $TimeoutSeconds - $clock.Elapsed.TotalSeconds
                    if ($remaining -gt 0 -and $PollSeconds -gt 0) {
                        Start-Sleep -Milliseconds ([int](1000 * [Math]::Min($PollSeconds, $remaining)))
                    }
                }
                if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { break }
            }
            if ($attempt -eq $MaxAttempts) {
                throw "Connector deployment failed after $MaxAttempts attempts: $lastError. Inspect $DeploymentPath."
            }
            Write-Host "  [retry] Connector deployment returned a transient error (attempt $attempt/$MaxAttempts)" -ForegroundColor Yellow
            $remaining = $TimeoutSeconds - $clock.Elapsed.TotalSeconds
            if ($remaining -gt 0 -and $PollSeconds -gt 0) {
                Start-Sleep -Milliseconds ([int](1000 * [Math]::Min($PollSeconds, $remaining)))
            }
        }
        throw "Connector deployment exceeded $TimeoutSeconds seconds (last result: $lastError). Inspect $DeploymentPath before retrying."
    } finally {
        if ($mayBeRunning) {
            try {
                $cancel = Invoke-ZavaArmRequest -Path "$DeploymentPath/cancel?api-version=2022-09-01" -Method Post -TimeoutSeconds 30
                $cancelNote = if ($cancel.StatusCode -in @(200, 202, 204)) {
                    'Cancellation requested.'
                } else {
                    "Cancellation returned HTTP $($cancel.StatusCode)."
                }
            } catch [OperationCanceledException], [Net.Http.HttpRequestException], [ArgumentException] {
                $cancelNote = "Cancellation could not be confirmed: $($_.Exception.Message)"
            }
            Write-Warning "$cancelNote Inspect $DeploymentPath before retrying; completed connector writes are not rolled back."
        }
    }
}

function Sync-ZavaConnectors {
    param(
        [object]$Plan,
        [string]$TemplatePath,
        [string]$AgentArmId,
        [string]$AppInsightsId,
        [string]$LogAnalyticsId,
        [int]$TimeoutSeconds = 600
    )
    $before = ConvertTo-Json -InputObject (ConvertTo-ZavaComparable $Plan.Existing) -Depth 40 -Compress
    $current = @(Get-ZavaArmConnectors $AgentArmId)
    $now = ConvertTo-Json -InputObject (ConvertTo-ZavaComparable $current) -Depth 40 -Compress
    if ($before -cne $now) { throw 'Connector inventory changed after preflight. Rerun to review the new state.' }

    $compiled = az bicep build --file $TemplatePath --stdout --only-show-errors 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Connector Bicep compilation failed: $compiled" }
    $template = $compiled | ConvertFrom-Json -ErrorAction Stop
    $agentName = ($AgentArmId -split '/')[-1]
    $scope = ($AgentArmId -split '/providers/')[0]
    # A lost PUT response must never pick up a previous invocation's success.
    $deploymentName = "zava-connectors-$([guid]::NewGuid().ToString('N'))"
    $parameters = @{
        agentName = @{ value = $agentName }
        appInsightsId = @{ value = $AppInsightsId }
        logAnalyticsId = @{ value = $LogAnalyticsId }
        connectorNames = @{ value = @($Plan.Definitions.name) }
        tagsByName = @{ value = $Plan.Tags }
    }
    Invoke-ZavaConnectorDeployment -Template $template -Parameters $parameters `
        -DeploymentPath "$scope/providers/Microsoft.Resources/deployments/$deploymentName" -TimeoutSeconds $TimeoutSeconds

    $actual = @(Get-ZavaArmConnectors $AgentArmId)
    $differences = [Collections.Generic.List[string]]::new()
    foreach ($connector in $Plan.Definitions) {
        $saved = @($actual | Where-Object name -ceq $connector.name)
        if ($saved.Count -ne 1) { $differences.Add("connectors/$($connector.name) is missing or duplicated"); continue }
        # ARM redacts source IDs and secret-backed settings. Verify exposed fields only.
        Compare-ExpectedProperties -Expected @{
            dataConnectorType = $connector.properties.dataConnectorType
            identity = $connector.properties.identity
            provisioningState = 'Succeeded'
        } -Actual $saved[0].properties -Path "connectors/$($connector.name)" -Differences $differences
    }
    if ($differences.Count) { throw "Connector readback failed: $($differences -join '; ')" }
    Write-Host '  [ok] Connector ARM provisioning and exposed properties verified' -ForegroundColor Green
}
