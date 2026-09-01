#Requires -Version 7.4
<#
.SYNOPSIS
    azd `predown` hook — removes subscription-level demo access and unlinks the
    Azure Monitor Private Link Scope (AMPLS) before resource-group teardown.

.DESCRIPTION
    AMPLS pins its scoped resources: a Log Analytics workspace (or App Insights
    component) that is a member of a private link scope CANNOT be deleted while
    the scopedResource link exists. ARM rejects the delete with
    `CannotDeleteWorkspaceWhenLinkedToPrivateLinkScopes`, which aborts the whole
    `azd down` and orphans the resource group.

    This hook removes the runtime identity's subscription Reader assignment and
    every scopedResource from every AMPLS in the resource group. A later
    re-provision recreates both.

    Idempotent: a no-op when there is no AMPLS (e.g. the lab was deployed with the
    private-link module disabled) or when the resource group is already gone.

.NOTES
    Wired as the azd `predown` hook in azure.yaml. Runs non-interactively.
#>
param(
    [string]$ResourceGroup
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not $ResourceGroup) {
    # RESOURCE_GROUP is an azd OUTPUT (only persisted after a fully successful
    # provision); ZAVA_RG_NAME is an optional override. Fall back to the standard
    # rg-$AZURE_ENV_NAME default so teardown of a partially-provisioned env still
    # finds the RG. Guard against `azd env get-value`'s "ERROR: ..." string for a
    # missing key (non-zero exit, printed to stdout).
    foreach ($k in 'RESOURCE_GROUP', 'ZAVA_RG_NAME') {
        $v = [Environment]::GetEnvironmentVariable($k)
        if (-not $v) {
            $v = azd env get-value $k 2>$null
            if ($LASTEXITCODE -ne 0) { $v = $null }
        }
        if ($v -and "$v".Trim() -and "$v" -notmatch '^ERROR') { $ResourceGroup = "$v".Trim(); break }
    }
    if (-not $ResourceGroup) {
        $environmentName = [Environment]::GetEnvironmentVariable('AZURE_ENV_NAME')
        if ($environmentName) { $ResourceGroup = "rg-$environmentName" }
    }
}

$savedPrincipalId = [Environment]::GetEnvironmentVariable('SRE_AGENT_PRINCIPAL_ID')
if (-not $savedPrincipalId) {
    $savedPrincipalId = azd env get-value SRE_AGENT_PRINCIPAL_ID 2>$null
    if ($LASTEXITCODE -ne 0 -or "$savedPrincipalId" -match '^ERROR') {
        $savedPrincipalId = $null
    }
}

if (-not $ResourceGroup -and -not $savedPrincipalId) {
    Write-Host "pre-down: neither resource group nor saved runtime principal is available — nothing to clean." -ForegroundColor DarkGray
    return
}

# The correlation role assignment lives outside the resource group and would
# otherwise survive `azd down`.
$resourceGroupExists = $ResourceGroup -and ((az group exists -n $ResourceGroup 2>$null) -eq 'true')
$principalIds = @()
if ($savedPrincipalId) {
    $principalIds += "$savedPrincipalId".Trim()
}
if ($resourceGroupExists) {
    $livePrincipalIds = az identity list -g $ResourceGroup `
        --query "[?starts_with(name, 'id-sre-agent-')].principalId" -o tsv 2>$null
    $principalIds += @($livePrincipalIds -split "`n" | Where-Object { $_ } | ForEach-Object { $_.Trim() })
}
$principalIds = @($principalIds | Where-Object { $_ } | Sort-Object -Unique)

$subscriptionId = az account show --query id -o tsv 2>$null
if ($LASTEXITCODE -eq 0 -and $subscriptionId) {
    $subscriptionScope = "/subscriptions/$subscriptionId"
    foreach ($principalId in $principalIds) {
        $assignmentIds = az role assignment list `
            --assignee-object-id $principalId `
            --scope $subscriptionScope `
            --query "[?roleDefinitionName=='Reader' && scope=='$subscriptionScope'].id" `
            -o tsv 2>$null

        foreach ($assignmentId in ($assignmentIds -split "`n" | Where-Object { $_ })) {
            $assignmentId = $assignmentId.Trim()
            Write-Host "pre-down: removing subscription Reader assignment for runtime identity..."
            az role assignment delete --ids $assignmentId 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  (warning: failed to remove '$assignmentId'; remove it manually to avoid an orphaned assignment)" -ForegroundColor Yellow
            }
        }
    }
}

if (-not $resourceGroupExists) {
    Write-Host "pre-down: resource group is absent; subscription assignment cleanup is complete." -ForegroundColor DarkGray
    return
}

Write-Host "pre-down: checking for Azure Monitor Private Link Scopes in '$ResourceGroup'..." -ForegroundColor Yellow

$amplsNames = az resource list -g $ResourceGroup `
    --resource-type 'Microsoft.Insights/privateLinkScopes' `
    --query "[].name" -o tsv 2>$null

if (-not $amplsNames) {
    Write-Host "pre-down: no AMPLS found — nothing to unlink." -ForegroundColor DarkGray
    return
}

foreach ($ampls in ($amplsNames -split "`n" | Where-Object { $_ })) {
    $ampls = $ampls.Trim()
    Write-Host "pre-down: unlinking scoped resources from AMPLS '$ampls'..." -ForegroundColor Yellow

    # List scoped resources (the workspace/App-Insights links that block deletion).
    $scoped = az monitor private-link-scope scoped-resource list `
        -g $ResourceGroup --scope-name $ampls --query "[].name" -o tsv 2>$null

    if (-not $scoped) {
        Write-Host "  (no scoped resources)" -ForegroundColor DarkGray
        continue
    }

    foreach ($s in ($scoped -split "`n" | Where-Object { $_ })) {
        $s = $s.Trim()
        Write-Host "  deleting scoped resource: $s"
        az monitor private-link-scope scoped-resource delete `
            -g $ResourceGroup --scope-name $ampls -n $s --yes 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  (warning: failed to delete scoped resource '$s'; teardown may still hit the AMPLS link)" -ForegroundColor Yellow
        }
    }
}

Write-Host "pre-down: external access cleanup and AMPLS unlink complete." -ForegroundColor Green
