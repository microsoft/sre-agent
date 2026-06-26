#Requires -Version 7.4
<#
.SYNOPSIS
    azd `predown` hook — unlinks the Azure Monitor Private Link Scope (AMPLS)
    before teardown so `azd down --purge` can delete/purge the Log Analytics
    workspace and Application Insights component.

.DESCRIPTION
    AMPLS pins its scoped resources: a Log Analytics workspace (or App Insights
    component) that is a member of a private link scope CANNOT be deleted while
    the scopedResource link exists. ARM rejects the delete with
    `CannotDeleteWorkspaceWhenLinkedToPrivateLinkScopes`, which aborts the whole
    `azd down` and orphans the resource group.

    This hook removes every scopedResource from every AMPLS in the resource group
    (cheap, instant, and reversible — a re-provision recreates them), so the
    subsequent workspace/App-Insights deletion + soft-delete purge succeeds.

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
    # provision); ZAVA_RG_NAME is the always-present INPUT. Fall back to it so
    # teardown of a partially-provisioned env (the exact case this hook hardens)
    # still finds the RG. Guard against `azd env get-value`'s "ERROR: ..." string
    # for a missing key (non-zero exit, printed to stdout).
    foreach ($k in 'RESOURCE_GROUP', 'ZAVA_RG_NAME') {
        $v = [Environment]::GetEnvironmentVariable($k)
        if (-not $v) {
            $v = azd env get-value $k 2>$null
            if ($LASTEXITCODE -ne 0) { $v = $null }
        }
        if ($v -and "$v".Trim() -and "$v" -notmatch '^ERROR') { $ResourceGroup = "$v".Trim(); break }
    }
}

if (-not $ResourceGroup) {
    Write-Host "pre-down: RESOURCE_GROUP not set — nothing to unlink." -ForegroundColor DarkGray
    return
}

if ((az group exists -n $ResourceGroup 2>$null) -ne 'true') {
    Write-Host "pre-down: resource group '$ResourceGroup' does not exist — nothing to unlink." -ForegroundColor DarkGray
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

Write-Host "pre-down: AMPLS unlink complete — workspace/App Insights are now deletable." -ForegroundColor Green
