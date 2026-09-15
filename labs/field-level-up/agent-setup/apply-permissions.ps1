#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [guid] $SubscriptionId,
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ResourceId,
    [switch] $CheckOnly
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

# Validate the entire ARM path before interpolation; never use SRE_AGENT_URL/ENDPOINT for authentication.
$resourcePattern = '^/subscriptions/' + [regex]::Escape($SubscriptionId.ToString()) +
    '/resourceGroups/[A-Za-z0-9_.()-]+/providers/Microsoft\.App/agents/[A-Za-z0-9][A-Za-z0-9-]*\z'
if ($ResourceId -notmatch $resourcePattern) {
    throw 'ResourceId must be an SRE Agent ARM resource ID in the supplied subscription, without query, fragment or encoded path segments.'
}
$armJson = & az rest --subscription $SubscriptionId --method get `
    --url "https://management.azure.com${ResourceId}?api-version=2026-01-01" --only-show-errors --output json 2>$null
if ($LASTEXITCODE -ne 0) { throw 'Unable to read the agent from ARM. Check the lab subscription and access.' }
try { $agent = ($armJson -join "`n") | ConvertFrom-Json }
catch { throw 'ARM returned an invalid agent response.' }
if ($agent.id -ine $ResourceId -or $agent.properties.actionConfiguration.mode -cne 'Review') {
    throw 'The ARM agent identity must match and actionConfiguration.mode must be Review. Review the agent in Azure manually.'
}

$endpoint = $agent.properties.agentEndpoint
$endpointUri = $null
if ($endpoint -isnot [string] -or
    -not [uri]::TryCreate($endpoint, [UriKind]::Absolute, [ref]$endpointUri) -or
    $endpoint -notmatch '^https://[A-Za-z0-9.-]+(?::443)?/?\z' -or
    $endpointUri.Scheme -ne 'https' -or $endpointUri.HostNameType -ne [UriHostNameType]::Dns -or
    $endpointUri.IsLoopback -or $endpointUri.UserInfo -or $endpointUri.Query -or $endpointUri.Fragment -or
    $endpointUri.AbsolutePath -ne '/' -or $endpointUri.Port -ne 443) {
    throw 'ARM must supply an HTTPS agent origin on port 443, without credentials, path, query or fragment.'
}
$settingsUri = $endpointUri.GetLeftPart([UriPartial]::Authority) + '/api/v2/agent/settings/global'
$desired = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'permissions.json') -Raw | ConvertFrom-Json -AsHashtable
$legacy = @{
    permissions = @{
        allow = @('GetAzCliHelp', 'ReadFile', 'GrepSearch', 'FetchGithubIssues')
        ask = @('*')
        deny = @()
    }
}

$token = $null
$headers = $null
try {
    # Capture only the token, never CLI credentials or HTTP response/error bodies in output.
    $token = & az account get-access-token --subscription $SubscriptionId --resource 'https://azuresre.dev' `
        --query accessToken --only-show-errors --output tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($token -join ''))) {
        throw 'Unable to obtain an SRE Agent token for the lab subscription. Sign in again and verify access.'
    }
    $headers = @{ Authorization = 'Bearer ' + ($token -join '').Trim() }
    # The legacy global-settings path ignores If-Match. Never install policy on that path.
    $featureUri = $endpointUri.GetLeftPart([UriPartial]::Authority) + '/api/v1/Feature/status/enableV2AgentLoop'
    try {
        $featureResponse = Invoke-WebRequest -Uri $featureUri -Method Get -Headers $headers -MaximumRedirection 0 `
            -MaximumRetryCount 0 -Verbose:$false -Debug:$false
        $feature = $featureResponse.Content | ConvertFrom-Json
    }
    catch { throw 'Unable to verify V2 permission concurrency support. No permissions were changed.' }
    if ($featureResponse.StatusCode -ne 200 -or $feature.enabled -isnot [bool] -or -not $feature.enabled) {
        throw 'V2 agent loop and workspace tools must already be enabled. No permissions were changed.'
    }
    try {
        $response = Invoke-WebRequest -Uri $settingsUri -Method Get -Headers $headers -MaximumRedirection 0 `
            -MaximumRetryCount 0 -Verbose:$false -Debug:$false
    }
    catch { throw 'Unable to read global settings. Check access and endpoint availability; redirects are not permitted.' }
    if ($response.StatusCode -ne 200) { throw 'Global settings GET did not return HTTP 200. No permissions were changed.' }
    try { $current = $response.Content | ConvertFrom-Json -AsHashtable }
    catch { throw 'Global settings returned invalid JSON. No permissions were changed.' }

    # Reject unknown shapes instead of interpreting them as an empty initial policy.
    if ($current -isnot [System.Collections.IDictionary] -or
        -not $current.Contains('permissions') -or $current.permissions -isnot [System.Collections.IDictionary] -or
        @($current.permissions.Keys | Where-Object { $_ -cnotin @('allow', 'ask', 'deny') }).Count -gt 0) {
        throw 'Unrecognized permission settings. Review the policy manually; no permissions were changed.'
    }
    $isEmpty = $true
    $isEqual = $true
    $isLegacyLabPolicy = $true
    foreach ($kind in @('allow', 'ask', 'deny')) {
        $rules = $current.permissions[$kind]
        if (-not $current.permissions.Contains($kind) -or $rules -isnot [array] -or
            @($rules | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
            throw 'Unrecognized permission rule list. Review the policy manually; no permissions were changed.'
        }
        if ($rules.Count -gt 0) { $isEmpty = $false }
        $actualSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($rule in $rules) { $null = $actualSet.Add($rule) }
        if (-not $actualSet.SetEquals([string[]]$desired.permissions[$kind])) { $isEqual = $false }
        if (-not $actualSet.SetEquals([string[]]$legacy.permissions[$kind])) { $isLegacyLabPolicy = $false }
    }
    if ($isEqual) {
        Write-Host 'Global permissions already match the lab policy; no changes made. ARM Review mode verified.'
        return
    }
    if (-not $isEmpty -and -not $isLegacyLabPolicy) {
        throw 'Existing nonempty global permissions differ from the lab policy. Review them manually in the agent settings against permissions.json. This script will not overwrite or merge them.'
    }
    if ($CheckOnly) {
        throw 'Global permissions are empty. Complete Part 2 permission setup separately before enabling incidents; this check made no changes.'
    }

    $etag = $null
    if ($response.Headers.ContainsKey('ETag')) {
        $etagValues = @($response.Headers['ETag'])
        if ($etagValues.Count -ne 1 -or [string]$etagValues[0] -notmatch '^"[^"\x00-\x20\x7f]+"\z') {
            throw 'Global settings returned an invalid strong ETag. No permissions were changed.'
        }
        $etag = [string]$etagValues[0]
    }
    elseif ($isLegacyLabPolicy) {
        throw 'The legacy lab policy was detected, but global settings returned no ETag. No permissions were changed.'
    }
    else {
        # Only a verified empty initial policy may use the API's create-if-absent wildcard.
        $etag = '*'
    }
    $headers['If-Match'] = $etag
    try {
        $update = Invoke-WebRequest -Uri $settingsUri -Method Put -Headers $headers -MaximumRedirection 0 `
            -ContentType 'application/json' -Body ($desired | ConvertTo-Json -Depth 10 -Compress) `
            -MaximumRetryCount 0 -Verbose:$false -Debug:$false
    }
    catch {
        if ([int]$_.Exception.Response.StatusCode -eq 412) {
            throw 'Permissions changed concurrently (HTTP 412). No retry or bypass was attempted. Review the current policy manually.'
        }
        throw 'Permission update failed. Review the current policy manually before rerunning; no retry was attempted.'
    }
    if ($update.StatusCode -ne 200) { throw 'Permission update did not return HTTP 200. Review the current policy manually.' }
    Write-Host 'Installed the lab global policy; Azure mutation tools are denied and incident reads/follow-ups are pre-authorized.'
}
finally {
    if ($headers) { $headers.Clear() }
    $token = $null
}