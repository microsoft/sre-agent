#Requires -Version 7.4
<#
.SYNOPSIS
    Configures the SRE Agent's data-plane-only state after `azd provision`.
.DESCRIPTION
    Most agent configuration is now declarative in Bicep
    (infra/modules/sre-agent.bicep): autonomous mode, AzMonitor incident
    platform, connectors (app-insights, log-analytics, azure-monitor, microsoft-learn),
    custom skills, and incident filters / response plans all flow through
    Microsoft.App/agents/* ARM resources.

    What stays in this script is the residual data-plane work that ARM does
    not yet expose:
      - Knowledge file upload (Builder UI > Knowledge sources)
      - Global tool enablement: turn the Microsoft Learn MCP tools ON for every
        agent loop. MCP connector tools ship `defaultMode: disabled` (skill-gated),
        and there is NO ARM/Bicep property for per-tool state (the agent's
        `permissions` stays null) — Microsoft's own `srectl tool config set` CLI
        exists for exactly this (POST /api/v2/agent/tools/configure).
      - Global tool DISABLEMENT: turn the built-in RunKubectl* tools OFF for every
        agent loop. The lab is fully kube-native — the agent runs `kubectl` in its
        sandbox terminal via managed-identity `kubelogin` — so these built-in tools
        are disabled at the agent level via the same POST
        /api/v2/agent/tools/configure API used to enable the Learn tools above.
      - Verification of Bicep-deployed assets
.EXAMPLE
    .\scripts\setup-sre-agent.ps1
#>
param(
    [string]$ResourceGroup = "",
    [string]$AgentName = "",
    [string]$SubscriptionId = ""
)

# Auto-detect from azd env if not provided
if (-not $ResourceGroup -or -not $AgentName) {
    try {
        $envText = azd env get-values 2>$null
        if ($envText) {
            $azdEnv = @{}
            $envText | ForEach-Object {
                if ($_ -match '^([^=]+)="?([^"]*)"?$') {
                    $azdEnv[$Matches[1]] = $Matches[2]
                }
            }
            if (-not $ResourceGroup) { $ResourceGroup = $azdEnv['RESOURCE_GROUP'] }
            if (-not $AgentName) { $AgentName = $azdEnv['SRE_AGENT_NAME'] }
        }
    } catch {}
}
if (-not $ResourceGroup -or -not $AgentName) {
    Write-Host "ERROR: Provide -ResourceGroup and -AgentName, or run from an azd environment." -ForegroundColor Red
    exit 1
}

$ErrorActionPreference = "Stop"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  SRE Agent Knowledge Sync + Verify" -ForegroundColor Cyan
Write-Host "  (agent itself is provisioned by Bicep)" -ForegroundColor DarkGray
Write-Host "========================================`n" -ForegroundColor Cyan

if (-not $SubscriptionId) {
    $SubscriptionId = az account show --query id -o tsv
}
$agentArmId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.App/agents/$AgentName"
$apiVersion = "2025-05-01-preview"

# --- Step 0: Verify agent exists -------------------------------------------
Write-Host "Step 0: Verifying agent exists..." -ForegroundColor Yellow
try {
    $agent = az rest --method GET --url "${agentArmId}?api-version=$apiVersion" 2>&1 | ConvertFrom-Json
    $agentEndpoint = $agent.properties.agentEndpoint
    Write-Host "  Agent: $AgentName" -ForegroundColor Green
    Write-Host "  Endpoint: $agentEndpoint" -ForegroundColor Green
} catch {
    Write-Host "  ERROR: Agent '$AgentName' not found in $ResourceGroup." -ForegroundColor Red
    Write-Host "  Run 'azd provision' first." -ForegroundColor Red
    exit 1
}

# --- Step 1: Acquire data plane token --------------------------------------
Write-Host "`nStep 1: Acquiring data plane token..." -ForegroundColor Yellow
$token = az account get-access-token --resource "https://azuresre.dev" --query accessToken -o tsv
$client = [System.Net.Http.HttpClient]::new()
$client.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $token)
$client.Timeout = [TimeSpan]::FromSeconds(30)
Write-Host "  Token acquired (audience: azuresre.dev)" -ForegroundColor Green

# --- Step 2: Sync knowledge files (data-plane only — no ARM equivalent) ----
# Knowledge files are stored as data-plane "connectors" of type KnowledgeFile,
# under the same /api/v2/extendedAgent/connectors collection that holds
# AppInsights/LogAnalytics/MCP connectors. The Builder UI > Knowledge Sources
# view filters this collection to dataConnectorType == "KnowledgeFile".
# PUT to /connectors/{filename} is idempotent (creates or replaces), so we
# don't need a separate DELETE step. The body shape mirrors what the portal
# UI sends, captured via Playwright network trace.
#
# Sync semantics: for every local *.md file in sre-config/knowledge-base/, we
# compute a SHA256 of the bytes and compare to a local hash cache. If the
# cached hash matches AND the named file is already present in the agent, we
# skip. Otherwise we PUT the file (which replaces any existing copy with the
# same name) and update the cache. The agent KB API does not surface a content
# hash on its file list, so a local sidecar cache is the simplest robust signal.
Write-Host "`nStep 2: Syncing knowledge files..." -ForegroundColor Yellow
$kbDir = Resolve-Path "$PSScriptRoot\..\sre-config\knowledge-base"
$kbLocalFiles = @(Get-ChildItem -Path $kbDir -Filter "*.md" -File)
$hashCachePath = Join-Path $kbDir ".upload-hashes.json"
$hashCache = @{}
if (Test-Path $hashCachePath) {
    try {
        $raw = Get-Content -Raw -Path $hashCachePath | ConvertFrom-Json
        foreach ($p in $raw.PSObject.Properties) { $hashCache[$p.Name] = $p.Value }
    } catch {
        Write-Host "  (hash cache unreadable, treating as empty)" -ForegroundColor DarkGray
    }
}

# Fetch the current set of remote KB files once. The /connectors endpoint
# returns all connector kinds; filter to dataConnectorType == "KnowledgeFile".
$remoteByName = @{}
$existingResp = $client.GetAsync("$agentEndpoint/api/v2/extendedAgent/connectors").Result
if ($existingResp.IsSuccessStatusCode) {
    $items = ($existingResp.Content.ReadAsStringAsync().Result | ConvertFrom-Json).value
    foreach ($f in @($items)) {
        if ($f.properties.dataConnectorType -eq "KnowledgeFile") { $remoteByName[$f.name] = $f }
    }
} else {
    Write-Host "  WARNING: could not list existing connectors ($($existingResp.StatusCode)); will attempt uploads anyway" -ForegroundColor Yellow
}

$sha256 = [System.Security.Cryptography.SHA256]::Create()
$uploaded = 0; $replaced = 0; $skipped = 0; $failed = 0

foreach ($localFile in $kbLocalFiles) {
    $kbFileName = $localFile.Name
    # Substitute placeholders so the agent KB reflects this deployment's resource group.
    # Convention matches Bicep skills (@@RG@@ -> actual resource group name).
    $kbText = [System.IO.File]::ReadAllText($localFile.FullName)
    $kbText = $kbText.Replace('@@RG@@', $ResourceGroup)
    $kbBytes = [System.Text.Encoding]::UTF8.GetBytes($kbText)
    $localHash = [System.BitConverter]::ToString($sha256.ComputeHash($kbBytes)).Replace("-", "").ToLowerInvariant()
    $remote = $remoteByName[$kbFileName]
    $cachedHash = $hashCache[$kbFileName]

    if ($remote -and $cachedHash -and ($cachedHash -eq $localHash)) {
        Write-Host "  [skip] $kbFileName unchanged (sha256=$($localHash.Substring(0,12))...)" -ForegroundColor DarkGray
        $skipped++
        continue
    }

    $isReplace = [bool]$remote
    $body = @{
        name = $kbFileName
        type = "KnowledgeItem"
        properties = @{
            dataConnectorType = "KnowledgeFile"
            dataSource = $kbFileName
            extendedProperties = @{
                displayName = $kbFileName
                fileContent = [System.Convert]::ToBase64String($kbBytes)
            }
        }
    } | ConvertTo-Json -Depth 6 -Compress
    $jsonContent = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, "application/json")
    $kbResp = $client.PutAsync("$agentEndpoint/api/v2/extendedAgent/connectors/$kbFileName", $jsonContent).Result
    if ($kbResp.IsSuccessStatusCode) {
        if ($isReplace) {
            Write-Host "  [replace] $kbFileName re-uploaded (sha256=$($localHash.Substring(0,12))...)" -ForegroundColor Cyan
            $replaced++
        } else {
            Write-Host "  [upload] $kbFileName uploaded (sha256=$($localHash.Substring(0,12))...)" -ForegroundColor Green
            $uploaded++
        }
        $hashCache[$kbFileName] = $localHash
    } else {
        Write-Host "  WARNING: upload of $kbFileName returned $($kbResp.StatusCode): $($kbResp.Content.ReadAsStringAsync().Result)" -ForegroundColor Yellow
        $failed++
    }
    $jsonContent.Dispose()
}
$sha256.Dispose()

# Persist updated hash cache.
try {
    ($hashCache | ConvertTo-Json) | Set-Content -Path $hashCachePath -Encoding UTF8
} catch {
    Write-Host "  (could not write hash cache to ${hashCachePath}: $($_.Exception.Message))" -ForegroundColor DarkGray
}

Write-Host ("  Summary: {0} uploaded, {1} replaced, {2} skipped, {3} failed (of {4} local files)" -f $uploaded, $replaced, $skipped, $failed, $kbLocalFiles.Count) -ForegroundColor Yellow

# --- Step 2b: Enable Microsoft Learn MCP tools globally (data-plane only) ----
# MCP connector tools ship `defaultMode: disabled` — they are skill-gated, i.e.
# only surface when an incident skill that lists them is active. To make the
# Microsoft Learn docs tools part of the GLOBAL tool roster (available to every
# agent loop, like the system MCP tools), they must be explicitly enabled.
# There is no ARM/Bicep property for per-tool enablement (the agent resource's
# `permissions` stays null); Microsoft added the `srectl tool config set` CLI for
# exactly this. The underlying call is POST /api/v2/agent/tools/configure with
# merge semantics: { overrides: [{ name, enabled }] }.
#
# The tools only appear in the catalog AFTER the microsoft-learn MCP connector
# completes its first tools/list handshake (which needs the GitHub-raw firewall
# allow in vnet.bicep + a warm connection), so we poll for them before enabling.
Write-Host "`nStep 2b: Enabling Microsoft Learn MCP tools globally..." -ForegroundColor Yellow
$learnTools = @(
    'microsoft-learn_microsoft_docs_search',
    'microsoft-learn_microsoft_code_sample_search',
    'microsoft-learn_microsoft_docs_fetch'
)
$catalog = @(); $present = @()
$toolDeadline = (Get-Date).AddMinutes(3)
do {
    try {
        $tr = $client.GetAsync("$agentEndpoint/api/v2/agent/tools").Result
        if ($tr.IsSuccessStatusCode) { $catalog = @(($tr.Content.ReadAsStringAsync().Result | ConvertFrom-Json).data) }
    } catch {}
    $present = @($learnTools | Where-Object { $_ -in $catalog.name })
    if ($present.Count -eq $learnTools.Count) { break }
    Start-Sleep -Seconds 15
} while ((Get-Date) -lt $toolDeadline)

if ($present.Count -lt $learnTools.Count) {
    Write-Host "  [WARN] Only $($present.Count)/$($learnTools.Count) Learn MCP tools visible in the catalog yet — the" -ForegroundColor Yellow
    Write-Host "         microsoft-learn MCP connection is still warming up (it fetches its server bits from" -ForegroundColor Yellow
    Write-Host "         raw.githubusercontent.com; confirm the allow-github-raw-mcp-bits firewall rule exists)." -ForegroundColor Yellow
    Write-Host "         Re-run this script shortly to finish enabling them." -ForegroundColor Yellow
}
if ($present.Count -gt 0) {
    $alreadyEnabled = @($catalog | Where-Object { ($_.name -in $present) -and $_.enabled } | ForEach-Object { $_.name })
    if ($alreadyEnabled.Count -eq $present.Count) {
        Write-Host "  [skip] $($present.Count) Learn MCP tool(s) already enabled globally" -ForegroundColor DarkGray
    } else {
        $payload = @{ overrides = @($present | ForEach-Object { @{ name = $_; enabled = $true } }) } | ConvertTo-Json -Depth 4 -Compress
        $cfgContent = [System.Net.Http.StringContent]::new($payload, [System.Text.Encoding]::UTF8, "application/json")
        $cfgResp = $client.PostAsync("$agentEndpoint/api/v2/agent/tools/configure", $cfgContent).Result
        if ($cfgResp.IsSuccessStatusCode) {
            Write-Host "  [ok] Enabled $($present.Count) Learn MCP tool(s) globally (docs_search, code_sample_search, docs_fetch)" -ForegroundColor Green
        } else {
            Write-Host "  WARNING: tool enable returned $($cfgResp.StatusCode): $($cfgResp.Content.ReadAsStringAsync().Result)" -ForegroundColor Yellow
        }
        $cfgContent.Dispose()
    }
}

# --- Step 2c: Disable the built-in RunKubectl* tools globally (data-plane) --
# This lab is fully kube-native: the agent runs `kubectl` itself in its sandbox
# terminal (RunInTerminal), authenticated by its managed identity via `kubelogin`.
# The built-in RunKubectl* tools are turned OFF at the agent level so the agent
# uses that native path. This is the same POST /api/v2/agent/tools/configure API
# Step 2b uses to enable the Learn tools, with a symmetric payload:
# { overrides: [{ name, enabled: false }] }. We disable the two raw-kubectl tools
# present in this agent's catalog (Read + Write) and union in any other tool whose
# name starts with 'RunKubectl' the live catalog reports, so we never POST a name
# the catalog can't confirm.
Write-Host "`nStep 2c: Disabling built-in RunKubectl* tools globally (kube-native)..." -ForegroundColor Yellow
$kubectlCore = @('RunKubectlReadCommand', 'RunKubectlWriteCommand')
$kcat = @()
try {
    $ktr = $client.GetAsync("$agentEndpoint/api/v2/agent/tools").Result
    if ($ktr.IsSuccessStatusCode) { $kcat = @(($ktr.Content.ReadAsStringAsync().Result | ConvertFrom-Json).data) }
} catch {}
# Always disable the two raw-kubectl tools; union in any other RunKubectl* the
# live catalog actually reports so we never POST a name it can't confirm.
$kubeFromCat = @($kcat | Where-Object { $_.name -like 'RunKubectl*' } | ForEach-Object { $_.name })
$kubectlTools = @($kubectlCore + $kubeFromCat | Select-Object -Unique)
# Built-in tools may not surface in the catalog readout, so skip only when the
# catalog positively confirms every target is present AND already disabled.
$kubePresent = @($kubectlTools | Where-Object { $_ -in $kcat.name })
$kubeStillOn = @($kcat | Where-Object { ($_.name -in $kubectlTools) -and $_.enabled } | ForEach-Object { $_.name })
if ($kubePresent.Count -gt 0 -and $kubePresent.Count -eq $kubectlTools.Count -and $kubeStillOn.Count -eq 0) {
    Write-Host "  [skip] RunKubectl* tools already disabled globally ($($kubectlTools -join ', '))" -ForegroundColor DarkGray
} else {
    $kPayload = @{ overrides = @($kubectlTools | ForEach-Object { @{ name = $_; enabled = $false } }) } | ConvertTo-Json -Depth 4 -Compress
    $kContent = [System.Net.Http.StringContent]::new($kPayload, [System.Text.Encoding]::UTF8, "application/json")
    $kResp = $client.PostAsync("$agentEndpoint/api/v2/agent/tools/configure", $kContent).Result
    if ($kResp.IsSuccessStatusCode) {
        Write-Host "  [ok] Disabled built-in kubectl tools globally ($($kubectlTools -join ', ')) — agent uses native kubectl via RunInTerminal" -ForegroundColor Green
    } else {
        Write-Host "  WARNING: kubectl tool disable returned $($kResp.StatusCode): $($kResp.Content.ReadAsStringAsync().Result)" -ForegroundColor Yellow
    }
    $kContent.Dispose()
}

# --- Step 3: Verify Bicep-deployed assets ----------------------------------
Write-Host "`nStep 3: Verifying Bicep-deployed configuration..." -ForegroundColor Yellow
$allGood = $true

function Get-AgentChildren {
    param([string]$Kind)
    (az rest --method GET --url "${agentArmId}/${Kind}?api-version=$apiVersion" 2>$null | ConvertFrom-Json).value
}

$connectors = @(Get-AgentChildren -Kind "connectors")
$expectedConnectors = @("app-insights","log-analytics","azure-monitor","microsoft-learn")
$missingConnectors = $expectedConnectors | Where-Object { $_ -notin $connectors.name }
if (-not $missingConnectors) { Write-Host "  [OK] Connectors: $($connectors.Count) (app-insights, log-analytics, azure-monitor, microsoft-learn)" -ForegroundColor Green }
else { Write-Host "  [MISSING] Connectors: $($missingConnectors -join ', ') — re-run azd provision" -ForegroundColor Red; $allGood = $false }

$skills = @(Get-AgentChildren -Kind "skills")
$expectedSkills = @("database-incidents","performance-incidents","application-incidents","general-triage","proactive-health-check")
$missingSkills = $expectedSkills | Where-Object { $_ -notin $skills.name }
if (-not $missingSkills) { Write-Host "  [OK] Custom skills: $($skills.Count)" -ForegroundColor Green }
else { Write-Host "  [MISSING] Skills: $($missingSkills -join ', ') — re-run azd provision" -ForegroundColor Red; $allGood = $false }

$filters = @(Get-AgentChildren -Kind "incidentFilters")
$expectedFilters = @("zava-database","zava-performance","zava-application","zava-unknown")
$missingFilters = $expectedFilters | Where-Object { $_ -notin $filters.name }
if (-not $missingFilters) { Write-Host "  [OK] Response plans: $($filters.Count)" -ForegroundColor Green }
else { Write-Host "  [MISSING] Response plans: $($missingFilters -join ', ') — re-run azd provision" -ForegroundColor Red; $allGood = $false }

$kbResp = $client.GetAsync("$agentEndpoint/api/v2/extendedAgent/connectors").Result
$knowledgeFiles = @()
if ($kbResp.IsSuccessStatusCode) {
    $knowledgeFiles = @(($kbResp.Content.ReadAsStringAsync().Result | ConvertFrom-Json).value | Where-Object { $_.properties.dataConnectorType -eq "KnowledgeFile" })
}
# Match against the actual local KB filenames so a partial sync (some files
# uploaded, others missing) doesn't pass verification just because the count
# is non-zero. The data-plane API stores files under their original name
# (no prefix) — see Step 2.
$expectedKb = @(Get-ChildItem -Path $kbDir -Filter '*.md' -ErrorAction SilentlyContinue |
    ForEach-Object { $_.Name })
$uploadedKbNames = @($knowledgeFiles | ForEach-Object { $_.name })
$missingKb = $expectedKb | Where-Object { $_ -notin $uploadedKbNames }
if ($expectedKb.Count -eq 0) {
    Write-Host "  [WARN] No local knowledge files found under sre-config/knowledge-base/" -ForegroundColor Yellow
} elseif (-not $missingKb) {
    Write-Host "  [OK] Knowledge files: $($knowledgeFiles.Count) (all $($expectedKb.Count) expected files present)" -ForegroundColor Green
} else {
    Write-Host "  [MISSING] Knowledge files: $($missingKb -join ', ') — re-run Step 2 (upload) above" -ForegroundColor Red; $allGood = $false
}

if ($agent.properties.actionConfiguration.mode -ne "autonomous") {
    Write-Host "  [WARN] Agent mode: $($agent.properties.actionConfiguration.mode) (expected autonomous)" -ForegroundColor Yellow; $allGood = $false
} else { Write-Host "  [OK] Mode: autonomous + access $($agent.properties.actionConfiguration.accessLevel)" -ForegroundColor Green }

if ($agent.properties.incidentManagementConfiguration.type -ne "AzMonitor") {
    Write-Host "  [WARN] Incident platform: $($agent.properties.incidentManagementConfiguration.type) (expected AzMonitor)" -ForegroundColor Yellow; $allGood = $false
} else { Write-Host "  [OK] Incident platform: AzMonitor" -ForegroundColor Green }

$learnEnabled = @()
$vcat = @()
try {
    $vt = $client.GetAsync("$agentEndpoint/api/v2/agent/tools").Result
    if ($vt.IsSuccessStatusCode) {
        $vcat = @(($vt.Content.ReadAsStringAsync().Result | ConvertFrom-Json).data)
        $learnEnabled = @($vcat | Where-Object { ($_.name -in $learnTools) -and $_.enabled } | ForEach-Object { $_.name })
    }
} catch {}
if ($learnEnabled.Count -eq $learnTools.Count) {
    Write-Host "  [OK] Microsoft Learn MCP tools enabled globally: $($learnEnabled.Count)/$($learnTools.Count)" -ForegroundColor Green
} else {
    Write-Host "  [WARN] Learn MCP tools enabled globally: $($learnEnabled.Count)/$($learnTools.Count) (MCP connection may still be warming up)" -ForegroundColor Yellow; $allGood = $false
}

$kubeVerifyOn = @($vcat | Where-Object { ($_.name -in $kubectlTools) -and $_.enabled } | ForEach-Object { $_.name })
if ($kubeVerifyOn.Count -eq 0) {
    Write-Host "  [OK] Built-in RunKubectl* tools disabled globally (agent is kube-native via RunInTerminal)" -ForegroundColor Green
} else {
    Write-Host "  [WARN] RunKubectl* still enabled: $($kubeVerifyOn -join ', ') — re-run Step 2c to disable" -ForegroundColor Yellow; $allGood = $false
}

if ($allGood) { Write-Host "  All Bicep + data-plane assets verified." -ForegroundColor Green }
else { Write-Host "  Some assets missing — see above." -ForegroundColor Yellow }

$client.Dispose()

# --- Summary ---------------------------------------------------------------
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Done" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "  DEPLOYED BY BICEP (verified above, not done by this script):" -ForegroundColor DarkGray
Write-Host "  [x] Agent: autonomous mode + High access"
Write-Host "  [x] Incident platform: Azure Monitor"
Write-Host "  [x] Connectors: app-insights, log-analytics, azure-monitor, microsoft-learn"
Write-Host "  [x] Custom skills: database-incidents, performance-incidents, application-incidents, general-triage, proactive-health-check"
Write-Host "  [x] Response plans (incident filters): zava-database, zava-performance, zava-application, zava-unknown"
Write-Host "`n  DONE BY THIS SCRIPT (data plane — no ARM API yet):" -ForegroundColor Cyan
Write-Host ("  [x] Knowledge files synced: {0} local file(s) ({1} uploaded, {2} replaced, {3} skipped, {4} failed)" -f $kbLocalFiles.Count, $uploaded, $replaced, $skipped, $failed)
Write-Host ("  [x] Microsoft Learn MCP tools enabled globally: {0}/{1} (docs_search, code_sample_search, docs_fetch)" -f $learnEnabled.Count, $learnTools.Count)
Write-Host ("  [x] Built-in RunKubectl* tools disabled globally: {0}/{1} (kube-native — agent runs kubectl in its sandbox terminal)" -f ($kubectlTools.Count - $kubeVerifyOn.Count), $kubectlTools.Count)

Write-Host "`n  NEXT STEPS:" -ForegroundColor Cyan
Write-Host "  Run a break scenario:"
Write-Host "    .\.github\skills\running-demo\scripts\break-sql.ps1      # Stop PostgreSQL"
Write-Host "    .\.github\skills\running-demo\scripts\break-network.ps1  # Block DB traffic"
Write-Host "    .\.github\skills\running-demo\scripts\break-db-perf.ps1  # Drop index"
Write-Host "  Watch the agent: https://sre.azure.com/agents$agentArmId`n"
