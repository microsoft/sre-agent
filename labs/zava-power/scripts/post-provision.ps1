#requires -Version 7.0
<#
postprovision hook — runs AFTER bicep deploy.
  1. Discover ACA FQDNs
  2. Build & push the 5 service images to ACR
  3. Write .lab-config.json (consumed by simulator)
  4. Render sre-config/ with substituted placeholders → .rendered/
  5. srectl apply to the ops agent (subagents, skills, hooks, scheduled tasks)
  6. pip install simulator deps
  7. Launch the simulator interactively (the ONE command finishes here)

Re-runnable. Idempotent except for image builds (which always rebuild).
#>
$ErrorActionPreference = 'Stop'
# Force UTF-8 to avoid Windows cp1252 UnicodeEncodeError in az CLI streaming output
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'
try { chcp 65001 | Out-Null } catch {}
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new() } catch {}
try { [Console]::InputEncoding  = [System.Text.UTF8Encoding]::new() } catch {}
$labRoot = Split-Path $PSScriptRoot -Parent
Push-Location $labRoot
try {
    Write-Host "`n═══ PowerGrid ZeroOps post-provision ═══" -ForegroundColor Cyan

    # ── azd env values (set by preprovision + bicep outputs) ──
    $env_obj = azd env get-values --output json | ConvertFrom-Json
    function Env([string]$k, [string]$default = '') {
        if ($env_obj.PSObject.Properties[$k] -and $env_obj.$k) { return $env_obj.$k }
        return $default
    }
    $sub        = Env 'AZURE_SUBSCRIPTION_ID'
    $rg         = Env 'AZURE_RESOURCE_GROUP'
    $loc        = Env 'AZURE_LOCATION'
    $appPrefix  = Env 'CONTAINER_APP_PREFIX' 'ca-powergrid'
    $workload   = Env 'WORKLOAD_NAME' 'powergrid'
    $opsAgent   = Env 'SRE_OPS_AGENT_NAME' 'sre-zavapower-ops'
    $acr        = Env 'CONTAINER_REGISTRY_NAME'
    if (-not $acr) {
        $acr = az acr list -g $rg --query "[0].name" -o tsv 2>$null
    }
    $snInstance = Env 'SERVICENOW_INSTANCE'
    $snUser     = Env 'SERVICENOW_USER' 'admin'

    Write-Host "  sub:    $sub"
    Write-Host "  rg:     $rg ($loc)"
    Write-Host "  acr:    $acr"
    Write-Host "  ops:    $opsAgent`n"

    # ── 1. Build & push the 5 service images ──
    Write-Host "═══ Building container images ═══" -ForegroundColor Cyan
    $services = @(
        @{ name = 'outage-api';       dir = 'src/outage-api';       image = "$appPrefix-outage" }
        @{ name = 'meter-api';        dir = 'src/meter-api';        image = "$appPrefix-meter" }
        @{ name = 'grid-status-api';  dir = 'src/grid-status-api';  image = "$appPrefix-grid" }
        @{ name = 'notification-svc'; dir = 'src/notification-svc'; image = "$appPrefix-notify" }
        @{ name = 'portal-web';       dir = 'src/portal-web';       image = "$appPrefix-portal" }
    )
    foreach ($svc in $services) {
        if (-not (Test-Path $svc.dir)) { Write-Host "  ⚠ $($svc.dir) missing, skipping" -ForegroundColor Yellow; continue }
        Write-Host "  ▶ building $($svc.image):latest ..."
        az acr build --registry $acr --image "$($svc.image):latest" $svc.dir --only-show-errors --no-logs 2>&1 | Select-Object -Last 3
        if ($LASTEXITCODE -ne 0) { throw "az acr build failed for $($svc.name)" }

        $appName = $svc.image
        Write-Host "    ⤷ rolling $appName to new image"
        az containerapp update -n $appName -g $rg --image "$acr.azurecr.io/$($svc.image):latest" --only-show-errors --query "name" -o tsv 2>$null | Out-Null
    }

    # ── 2. Discover FQDNs ──
    Write-Host "`n═══ Discovering FQDNs ═══" -ForegroundColor Cyan
    $fqdns = @{}
    foreach ($key in @{ outage = "$appPrefix-outage"; grid = "$appPrefix-grid"; notify = "$appPrefix-notify"; portal = "$appPrefix-portal" }.GetEnumerator()) {
        $fq = az containerapp show -n $key.Value -g $rg --query "properties.configuration.ingress.fqdn" -o tsv 2>$null
        if ($fq) { $fqdns[$key.Key] = "https://$fq"; Write-Host "    $($key.Key) → $fq" -ForegroundColor DarkGray }
    }

    # ── 3. Write .lab-config.json ──
    Write-Host "`n═══ Writing .lab-config.json ═══" -ForegroundColor Cyan
    $rbacTier = Env 'RBAC_TIER' 'custom'
    $cfg = [ordered]@{
        azure = [ordered]@{
            subscriptionId      = $sub
            resourceGroup       = $rg
            region              = $loc
            workloadName        = $workload
            containerAppPrefix  = $appPrefix
        }
        services = [ordered]@{
            outageApiUrl = $fqdns['outage']
            gridApiUrl   = $fqdns['grid']
            notifyUrl    = $fqdns['notify']
            portalUrl    = $fqdns['portal']
        }
        sreAgent = [ordered]@{
            opsAgentName       = $opsAgent
            rbacTier           = $rbacTier
        }
        serviceNow = [ordered]@{ instance = $snInstance; user = $snUser }
        demo = [ordered]@{
            employeeName = 'Demo User'; employeeEmail = 'demo@zavapower.com'; employeeId = 'EMP-001'
        }
    }
    $cfg | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $labRoot '.lab-config.json') -Encoding utf8
    Write-Host "  ✓ .lab-config.json written (rbacTier=$rbacTier)"

    # ── 4. Render sre-config ──
    Write-Host "`n═══ Rendering sre-config ═══" -ForegroundColor Cyan
    $rendered = Join-Path $labRoot '.rendered/sre-config'
    & python (Join-Path $PSScriptRoot 'render-config.py') `
        --src (Join-Path $labRoot 'sre-config') --dest $rendered `
        --vars "AZ_SUBSCRIPTION_ID=$sub" `
        --vars "AZ_RG=$rg" --vars "AZ_REGION=$loc" `
        --vars "AZ_APP_PREFIX=$appPrefix" --vars "AZ_WORKLOAD=$workload" `
        --vars "SRE_OPS_AGENT_NAME=$opsAgent" `
        --vars "SN_INSTANCE=$snInstance" `
        --vars "DEMO_EMPLOYEE_EMAIL=$(Env 'DEMO_EMPLOYEE_EMAIL' 'demo.user@zavapower.com')" `
        --vars "ADO_ORG=$(Env 'ADO_ORG' 'placeholder-ado-org')" `
        --vars "ADO_REPO=$(Env 'ADO_REPO' 'placeholder-ado-repo')" `
        --vars "GH_TEMPLATE_ORG=$(Env 'GH_TEMPLATE_ORG' 'microsoft')" `
        --vars "GH_USER=$(Env 'GH_USER' 'demo-user')" `
        --vars "ADO_PROJECT=$(Env 'ADO_PROJECT' 'placeholder-ado-project')" `
        --vars "GH_REPO=$(Env 'GH_REPO' 'placeholder-gh-repo')" `
        --vars "GH_TEMPLATE_REPO=$(Env 'GH_TEMPLATE_REPO' 'placeholder-gh-template-repo')"
    if ($LASTEXITCODE -ne 0) { throw "render-config.py failed" }

    # ── 5. srectl apply ──
    # Resolve agent HTTPS endpoint from ARM — srectl init expects this, NOT an ARM resource id.
    # (Reused below by step 5.5 for HTTP trigger registration.)
    $opsAgentResId = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.App/agents/$opsAgent"
    $agentApiVersion = '2025-05-01-preview'
    $opsEndpoint = az resource show --ids $opsAgentResId --api-version $agentApiVersion --query "properties.agentEndpoint" -o tsv 2>$null
    if (-not $opsEndpoint) {
        # Fallback for older API surface
        $opsEndpoint = az resource show --ids $opsAgentResId --api-version $agentApiVersion --query "properties.endpoint" -o tsv 2>$null
    }
    if ($opsEndpoint -and $opsEndpoint -notmatch '^https?://') { $opsEndpoint = "https://$opsEndpoint" }

    if ($env:LABS_SKIP_SRECTL -eq '1') {
        Write-Host "`n═══ Skipping srectl (LABS_SKIP_SRECTL=1 — infra-only mode) ═══" -ForegroundColor Yellow
        Write-Host "  Apply config later with:"
        Write-Host "    srectl init --resource-url $opsEndpoint"
        Write-Host "    Get-ChildItem .rendered -Recurse -Filter *.yaml | %% { srectl apply-yaml --file `$_.FullName }"
    } elseif (-not (Get-Command srectl -ErrorAction SilentlyContinue)) {
        Write-Host "`n═══ srectl not on PATH — skipping config apply ═══" -ForegroundColor Yellow
        Write-Host "  This is expected if you don't have SRE Agent private-preview access yet."
        Write-Host "  Infra is deployed; request srectl access at aka.ms/sreagent-onboarding."
    } elseif (-not $opsEndpoint) {
        Write-Host "`n═══ srectl skipped — could not resolve agent HTTPS endpoint ═══" -ForegroundColor Yellow
        Write-Host "  Agent ARM id: $opsAgentResId"
        Write-Host "  Check 'az resource show --ids <id> --query properties.endpoint' manually."
    } else {
        Write-Host "`n═══ Applying SRE Agent config (ops) ═══" -ForegroundColor Cyan
        Write-Host "  srectl endpoint: $opsEndpoint" -ForegroundColor DarkGray
        srectl init --resource-url $opsEndpoint 2>&1 | Select-Object -Last 3
        foreach ($kind in 'connectors','tools','skills','agents','scheduled-tasks','response-plans') {
            $dir = Join-Path $rendered $kind
            if (-not (Test-Path $dir)) { continue }
            Get-ChildItem $dir -Recurse -Filter *.yaml -File | ForEach-Object {
                srectl apply-yaml --file $_.FullName 2>&1 | Select-Object -Last 1
            }
        }
    }

    # ── 5.5 Register HTTP trigger for the simulator ──
    $opsHttpTriggerUrl = ''
    $opsHttpTriggerId  = ''
    Write-Host "`n═══ Registering HTTP trigger (ops) ═══" -ForegroundColor Cyan
    $platformHelper = Join-Path (Split-Path $labRoot -Parent) '_platform/http_trigger.py'
    if (-not (Test-Path $platformHelper)) {
        Write-Host "  ⏭️  Skipped — labs/_platform/http_trigger.py not found" -ForegroundColor Yellow
    } else {
        # $opsAgentResId + $opsEndpoint already resolved in step 5
        if (-not $opsEndpoint) {
            Write-Host "  ⏭️  Skipped — could not resolve SRE agent HTTP endpoint via ARM" -ForegroundColor Yellow
        } else {
            Write-Host "  endpoint: $opsEndpoint"
            $htJson = & python $platformHelper create-and-enable `
                --endpoint $opsEndpoint `
                --name 'zava-power-ops-trigger' `
                --agent 'incident-handler' `
                --mode 'autonomous' `
                --description 'Fired by the PowerGrid simulator when it observes sustained grid-status slowness or other failure signals.' `
                --prompt 'Incoming alert payload from the PowerGrid (Zava Power) lab simulator. Investigate the affected service health, follow the incident-handler runbook, and post a brief diagnosis + recommended remediation.'
            if ($LASTEXITCODE -eq 0 -and $htJson) {
                try {
                    $htObj = $htJson | ConvertFrom-Json
                    $opsHttpTriggerUrl = [string]$htObj.triggerUrl
                    $opsHttpTriggerId  = [string]$htObj.triggerId
                } catch {}
                if ($opsHttpTriggerUrl) {
                    azd env set POWERGRID_SRE_TRIGGER_URL $opsHttpTriggerUrl 2>$null | Out-Null
                    azd env set ZAVA_HTTP_TRIGGER_URL    $opsHttpTriggerUrl 2>$null | Out-Null
                    Write-Host "  ✓ trigger registered: $opsHttpTriggerId" -ForegroundColor Green
                    # Patch .lab-config.json (consumed by simulator)
                    $cfgPath = Join-Path $labRoot '.lab-config.json'
                    if (Test-Path $cfgPath) {
                        $cfgObj = Get-Content $cfgPath -Raw | ConvertFrom-Json
                        if (-not $cfgObj.sreAgent.PSObject.Properties['opsHttpTriggerUrl']) {
                            $cfgObj.sreAgent | Add-Member -NotePropertyName opsHttpTriggerUrl -NotePropertyValue $opsHttpTriggerUrl -Force
                        } else {
                            $cfgObj.sreAgent.opsHttpTriggerUrl = $opsHttpTriggerUrl
                        }
                        $cfgObj | ConvertTo-Json -Depth 10 | Set-Content $cfgPath -Encoding utf8
                        Write-Host "  ✓ .lab-config.json updated with sreAgent.opsHttpTriggerUrl"
                    }
                } else {
                    Write-Host "  ⚠ trigger create returned no URL: $htJson" -ForegroundColor Yellow
                }
            } else {
                Write-Host "  ⚠ http_trigger.py failed (exit $LASTEXITCODE)" -ForegroundColor Yellow
            }
        }
    }

    # ── 6. Install simulator deps ──
    Write-Host "`n═══ Preparing simulator ═══" -ForegroundColor Cyan
    & python -m pip install -q -r (Join-Path $labRoot 'simulator/requirements.txt')

    # ── 7. Write .deployed/<name>.json (consumed by labs/sim.ps1 meta-sim) ──
    $deployedDir = Join-Path (Split-Path $labRoot -Parent) '.deployed'
    if (-not (Test-Path $deployedDir)) { New-Item -ItemType Directory -Path $deployedDir -Force | Out-Null }
    $deployedRecord = [ordered]@{
        name           = 'zava-power'
        deployedAt     = (Get-Date).ToString('o')
        subscriptionId = $sub
        resourceGroup  = $rg
        region         = $loc
        sreAgentName   = $opsAgent
        portalUrl      = $fqdns['portal']
        httpTriggerUrl = $opsHttpTriggerUrl
        httpTriggerId  = $opsHttpTriggerId
        labConfigPath  = (Join-Path $labRoot '.lab-config.json')
    }
    $deployedRecord | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $deployedDir 'zava-power.json') -Encoding utf8
    Write-Host "  ✓ recorded in $deployedDir\zava-power.json (meta-sim will see it)"

    # ── 8. RBAC tier banner ──
    $tierMsg = switch ($rbacTier) {
        'custom'      { @{ icon='✅'; label='T1 (custom least-priv)';      capability='Full remediation via PowerGrid SRE Agent Operator (11 specific actions on rg).' } }
        'contributor' { @{ icon='⚠'; label='T2 (built-in Contributor)';   capability='Full remediation via Contributor on rg. Broader perms than T1 — fallback because custom role unavailable.' } }
        'readonly'    { @{ icon='ℹ'; label='T3 (read-only)';              capability='Detect + diagnose only. Remediation requests are routed via the agent approval flow to a human admin.' } }
        default       { @{ icon='?'; label="unknown ($rbacTier)";         capability='' } }
    }
    Write-Host ""
    Write-Host "═══ RBAC tier: $($tierMsg.icon) $($tierMsg.label) ═══" -ForegroundColor Cyan
    Write-Host "  $($tierMsg.capability)" -ForegroundColor DarkGray
    if ($rbacTier -ne 'custom') {
        Write-Host "  To upgrade later:  azd env set RBAC_TIER custom && azd provision" -ForegroundColor DarkGray
    }

    # ── 9. Launch the simulator ──
    if ($env:LAB_NO_AUTOLAUNCH) {
        Write-Host "`n═══ Done — simulator NOT auto-launched (LAB_NO_AUTOLAUNCH set) ═══" -ForegroundColor Green
        Write-Host "  Run manually:  python simulator/demo.py" -ForegroundColor DarkGray
        Write-Host "  Or use the Zava Unlimited meta-sim:  pwsh ../sim.ps1`n" -ForegroundColor DarkGray
    } else {
        Write-Host "`n═══ All set — launching simulator ═══`n" -ForegroundColor Green
        Write-Host "  (.lab-config.json wired with your deploy. Use Ctrl+C to exit anytime)`n" -ForegroundColor DarkGray
        & python (Join-Path $labRoot 'simulator/demo.py')
    }
}
finally {
    Pop-Location
}
