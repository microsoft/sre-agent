<#
.SYNOPSIS
    Applies agent configuration via data-plane API.

.DESCRIPTION
    Two auth paths:

      1. Data-plane (skills, subagents, tools, connectors, incidentFilters,
         scheduledTasks, commonPrompts, hooks, httpTriggers, repos, knowledge)
         — requires token for audience https://azuresre.dev.

      2. ARM (agent resource itself, incident platform PATCH)
         — uses `az rest` with management-plane token.

    Auth:
      ARM calls         → `az login` (control-plane token, always available)
      data-plane calls  → token with audience https://azuresre.dev
                          (`az account get-access-token --resource ...`)
                          Optional — script continues if unavailable

    Repo auth (GitHub / ADO):
      GitHub — two paths, the script picks based on what env vars are set:
        1. OAuth (default): no env vars needed. Script prints a sign-in URL at the
           end. Click it, approve in the browser, GitHub redirects back to the
           agent and the token is stored. No secrets in env.
        2. PAT (optional, headless): set $env:GITHUB_PAT=ghp_xxx before running.
           Script POSTs the PAT silently — no browser.
      ADO — set $env:ADO_PAT, $env:ADO_USE_AAD=1, or $env:ADO_USE_MI=1 (with $env:ADO_ORG).

.PARAMETER Subscription
    Azure subscription ID.

.PARAMETER ResourceGroup
    Resource group containing the agent.

.PARAMETER AgentName
    Name of the SRE Agent resource.

.PARAMETER ExtrasFile
    Path to the extras.parameters.json file. Defaults to extras.parameters.json in current dir.

.PARAMETER Force
    Force overwrite without prompting.

.EXAMPLE
    ./Apply-Extras.ps1 -Subscription <sub-id> -ResourceGroup rg-myagent -AgentName myagent
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [Alias('SubscriptionId')]
    [string]$Subscription,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$AgentName,
    # Either supply a pre-assembled extras JSON OR a config directory — Apply-Extras
    # will auto-assemble from the directory if ExtrasFile is not found.
    [string]$ExtrasFile = "",
    [string]$ConfigDir  = "",
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ── Validate prerequisites ──────────────────────────────────────────────────
$PrereqScript = Join-Path $PSScriptRoot 'Check-Prerequisites.ps1'
if (Test-Path $PrereqScript) {
    . $PrereqScript
    if (-not (Test-Prerequisites -IncludeCurl -IncludeTar)) { exit 1 }
} else {
    # Fallback: inline check
    foreach ($cmd in @('jq', 'tar')) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            Write-Error "$cmd is required"; return
        }
    }
}

# ── Auto-assemble from ConfigDir if ExtrasFile not supplied/found ───────────
if (($ExtrasFile -eq "" -or -not (Test-Path $ExtrasFile)) -and $ConfigDir -ne "" -and (Test-Path $ConfigDir -PathType Container)) {
    Write-Host "No extras file supplied — assembling from config dir: $ConfigDir"
    $AssembleScript = Join-Path $PSScriptRoot 'Assemble-Agent.ps1'
    $AssembleTmp = Join-Path ([System.IO.Path]::GetTempPath()) "assembled-$(New-Guid)"
    & $AssembleScript -ConfigDir $ConfigDir -Output $AssembleTmp
    $ExtrasFile = "${AssembleTmp}.extras.json"
} elseif ($ExtrasFile -eq "") {
    # Default: look for <AgentName>.extras.json next to the script caller's cwd
    $ExtrasFile = "extras.parameters.json"
}

if (-not (Test-Path $ExtrasFile)) {
    Write-Error "extras file not found: $ExtrasFile`nTip: pass -ConfigDir <agent-dir> to auto-assemble."
    return
}

# Disable strict mode (inherited from Deploy-Agent) — this script expects
# many optional keys on $extras that may be absent for minimal recipes.
Set-StrictMode -Off

$ApiVersion = "2025-05-01-preview"
$ArmBase = "https://management.azure.com/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.App/agents/$AgentName"

# ── Resolve agent endpoint and UAMI ────────────────────────────────────────
try {
    $agentRaw = (az rest -m GET --url "$ArmBase`?api-version=$ApiVersion" -o json 2>$null) -join "`n"
    $agentObj = $agentRaw | ConvertFrom-Json
} catch {
    $agentObj = $null
}

$AgentEndpoint = $null
$AgentUami = $null

if ($agentObj) {
    $AgentEndpoint = $agentObj.properties.agentEndpoint
    $uamiKeys = $agentObj.identity.userAssignedIdentities.PSObject.Properties.Name
    if ($uamiKeys) { $AgentUami = $uamiKeys | Select-Object -First 1 }
}

if (-not $AgentEndpoint) {
    Write-Error "Could not resolve agent endpoint. Is $AgentName provisioned in ${ResourceGroup}?"
    return
}

Write-Host "Agent endpoint: $AgentEndpoint"
if ($AgentUami) {
    Write-Host "Agent UAMI:     $($AgentUami.Split('/')[-1])"
}

# ── Probe data-plane token availability ─────────────────────────────────────
$DpTokenAvailable = $false
$DpSkippedItems = [System.Collections.Generic.List[string]]::new()

try {
    $null = az account get-access-token --resource https://azuresre.dev --query accessToken -o tsv 2>$null
    if ($LASTEXITCODE -eq 0) {
        $DpTokenAvailable = $true
        Write-Host "Data-plane:     token available"
    } else {
        throw "token unavailable"
    }
} catch {
    Write-Host "Data-plane:     token unavailable (hooks, repos, httpTriggers will be skipped)"
    Write-Host "                To apply later: az login --scope `"https://azuresre.dev/.default`" && re-run"
}

# ── Load extras JSON ────────────────────────────────────────────────────────
$extras = Get-Content -Raw $ExtrasFile | ConvertFrom-Json

# ── Helper: get data-plane bearer token ─────────────────────────────────────
function Get-DpToken {
    $tok = az account get-access-token --resource https://azuresre.dev --query accessToken -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $tok) {
        throw "Could not get data-plane token (audience https://azuresre.dev)"
    }
    return $tok
}

# ── Helper: ARM PUT sub-resource with base64-encoded value envelope ─────────
# Used for incidentFilters, scheduledTasks, commonPrompts.
function Arm-PutSubresource {
    param([string]$Type, [string]$Name, [string]$SpecJson)
    $url = "$ArmBase/$Type/$Name`?api-version=$ApiVersion"
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($SpecJson))
    $body = @{ properties = @{ value = $encoded } } | ConvertTo-Json -Compress -Depth 10
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -Path $tmp -Value $body -NoNewline
        Write-Host "  ARM PUT $Type/$Name"
        $result = az rest -m PUT --url $url --body "@$tmp" --headers "Content-Type=application/json" -o json 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    ok"
        } else {
            $msg = ($result | Out-String) -replace '(?s).*"message":"([^"]*)".*', '$1'
            Write-Host "    FAILED - $msg"
        }
    } finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
}

# ── Helper: ARM PUT connector sub-resource (native properties, no base64) ──
function Arm-PutConnector {
    param([string]$Name, [string]$BodyJson)
    $url = "$ArmBase/connectors/$Name`?api-version=$ApiVersion"
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -Path $tmp -Value $BodyJson -NoNewline
        Write-Host "  ARM PUT connectors/$Name"
        $result = az rest -m PUT --url $url --body "@$tmp" --headers "Content-Type=application/json" -o json 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    ok"
        } else {
            $msg = ($result | Out-String) -replace '(?s).*"message":"([^"]*)".*', '$1'
            Write-Host "    FAILED - $msg"
        }
    } finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
}

# ── Helper: build tar.gz from inline files array, upload to data-plane ──────
function DataPlane-UploadTarball {
    param([string]$Label, [string]$Url, [array]$FilesArray)
    $stage = Join-Path ([System.IO.Path]::GetTempPath()) "extras-$([guid]::NewGuid())"
    $tarball = Join-Path ([System.IO.Path]::GetTempPath()) "extras-$([guid]::NewGuid()).tar.gz"
    try {
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        $n = $FilesArray.Count
        foreach ($f in $FilesArray) {
            $fullPath = Join-Path $stage $f.path
            $dir = Split-Path $fullPath -Parent
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Set-Content -Path $fullPath -Value $f.content -NoNewline
        }

        tar -czf $tarball -C $stage .
        $token = Get-DpToken

        $suffix = if ($n -eq 1) { "" } else { "s" }
        Write-Host "  data-plane POST $Label  ($n file$suffix)"

        $headers = @{
            Authorization  = "Bearer $token"
            "Content-Type" = "application/gzip"
        }
        $bytes = [System.IO.File]::ReadAllBytes($tarball)
        $null = Invoke-RestMethod -TimeoutSec 30 -Uri $Url -Method Post -Headers $headers -Body $bytes
        Write-Host "    ok"
    } catch {
        Write-Host "    FAILED - POST $Url"
    } finally {
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $tarball -Force -ErrorAction SilentlyContinue
    }
}

# ── Helper: upload one file via multipart/form-data to AgentMemory ──────────
function DataPlane-UploadMultipart {
    param([string]$Label, [string]$Url, [string]$Filename, [string]$Mime, [string]$Trigger, [string]$SrcPath)
    try {
        $token = Get-DpToken
    } catch {
        Write-Host "    FAILED - could not get data-plane token"
        return
    }

    Write-Host "  data-plane multipart POST $Label ($Filename)"
    try {
        $fileBytes = [System.IO.File]::ReadAllBytes($SrcPath)
        $boundary = [guid]::NewGuid().ToString()
        $LF = "`r`n"

        $bodyLines = @(
            "--$boundary"
            "Content-Disposition: form-data; name=`"files`"; filename=`"$Filename`""
            "Content-Type: $Mime"
            ""
        )
        $headerBytes = [System.Text.Encoding]::UTF8.GetBytes(($bodyLines -join $LF) + $LF)
        $footerBytes = [System.Text.Encoding]::UTF8.GetBytes("$LF--$boundary--$LF")

        $bodyStream = [System.IO.MemoryStream]::new()
        $bodyStream.Write($headerBytes, 0, $headerBytes.Length)
        $bodyStream.Write($fileBytes, 0, $fileBytes.Length)
        $bodyStream.Write($footerBytes, 0, $footerBytes.Length)
        $bodyArray = $bodyStream.ToArray()
        $bodyStream.Dispose()

        $fullUrl = "${Url}?triggerIndexing=$Trigger"
        $headers = @{ Authorization = "Bearer $token" }
        $null = Invoke-WebRequest -TimeoutSec 30 -Uri $fullUrl -Method Post `
            -Headers $headers `
            -ContentType "multipart/form-data; boundary=$boundary" `
            -Body $bodyArray
        Write-Host "    ok"
    } catch {
        Write-Host "    FAILED - POST $Url"
    }
}

# ── Helper: POST a plugin/installation JSON document (data-plane v2) ────────
function DataPlane-PostJson {
    param([string]$Label, [string]$Url, [object]$BodyObj)
    try {
        $token = Get-DpToken
    } catch {
        Write-Host "    FAILED - could not get data-plane token"
        return
    }
    Write-Host "  data-plane POST $Label"
    try {
        $headers = @{
            Authorization  = "Bearer $token"
            "Content-Type" = "application/json"
        }
        $bodyJson = $BodyObj | ConvertTo-Json -Compress -Depth 20
        $null = Invoke-RestMethod -TimeoutSec 30 -Uri $Url -Method Post -Headers $headers -Body $bodyJson -ContentType "application/json"
        Write-Host "    ok"
    } catch {
        Write-Host "    FAILED - POST $Url"
    }
}

# ── Helper: PUT to v2 extendedAgent data-plane (hooks/commonprompts/plugins) ─
function DataPlane-PutExtended {
    param([string]$Kind, [string]$Name, [string]$Type, [array]$Tags, [object]$Properties)
    $token = Get-DpToken
    $body = @{
        name       = $Name
        type       = $Type
        tags       = @($Tags)
        properties = $Properties
    } | ConvertTo-Json -Compress -Depth 20
    $encodedName = [uri]::EscapeDataString($Name)
    $url = "$AgentEndpoint/api/v2/extendedAgent/$Kind/$encodedName"
    try {
        $headers = @{
            Authorization  = "Bearer $token"
            "Content-Type" = "application/json"
        }
        $null = Invoke-RestMethod -TimeoutSec 30 -Uri $url -Method Put -Headers $headers -Body $body -ContentType "application/json"
        Write-Host "  ok $Kind/$Name"
    } catch {
        Write-Host "  FAILED - PUT $Kind/$Name"
    }
}

# ── Generic processor for hooks / commonPrompts / pluginConfigs entries ─────
function Process-ExtendedItems {
    param([string]$JqKey, [string]$Kind, [object]$Items)
    $count = ($Items | Measure-Object).Count
    if ($count -eq 0) { return }
    Write-Host "${JqKey}: $count"
    foreach ($item in $Items) {
        $name = $item.name
        $type = if ($item.type) { $item.type } else { "" }
        $tags = if ($item.tags) { @($item.tags) } else { @() }
        $props = if ($item.properties) { $item.properties } else { @{} }
        DataPlane-PutExtended -Kind $Kind -Name $name -Type $type -Tags $tags -Properties $props
    }
}

Write-Host "Applying extras to $AgentName in $ResourceGroup..."

# ═════════════════════════════════════════════════════════════════════════════
# 1. incidentPlatforms — ARM PATCH on agent resource (not sub-resource PUT)
# ═════════════════════════════════════════════════════════════════════════════
$incidentPlatforms = $extras.incidentPlatforms
$ipCount = ($incidentPlatforms | Measure-Object).Count
if ($ipCount -gt 0) {
    Write-Host "incidentPlatforms: $ipCount"
    $platform = $incidentPlatforms[0]
    $platformType = if ($platform.spec.platformType) { $platform.spec.platformType }
                    elseif ($platform.spec.incidentPlatform) { $platform.spec.incidentPlatform }
                    else { $null }
    if ($platformType) {
        $connKey = $platform.spec.connectionKey
        Write-Host "  ARM PATCH -> incidentManagementConfiguration.type=$platformType"
        $connName = $platformType.ToLower()
        $patchProps = @{ type = $platformType; connectionName = $connName }
        if ($connKey) { $patchProps.connectionKey = $connKey }
        $patchBody = @{ properties = @{ incidentManagementConfiguration = $patchProps } } | ConvertTo-Json -Compress -Depth 10
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            Set-Content -Path $tmp -Value $patchBody -NoNewline
            $patchOut = az rest --method PATCH --url "$ArmBase`?api-version=$ApiVersion" --body "@$tmp" --headers "Content-Type=application/json" -o json 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "    ok"
            } else {
                Write-Host "    FAILED - could not set incident platform"
                Write-Host "    Body sent: $patchBody"
                Write-Host "    Response : $($patchOut | Out-String)"
            }
        } finally {
            Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
        }
        Write-Host "  Waiting 30s for platform to initialize..."
        Start-Sleep -Seconds 30
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# 1b. incidentFilters — data-plane PUT with retry
# Route: PUT /api/v2/extendedAgent/incidentFilters/{name}
# ═════════════════════════════════════════════════════════════════════════════
$incidentFilters = $extras.incidentFilters
$ifCount = ($incidentFilters | Measure-Object).Count
if ($ifCount -gt 0) {
    if ($DpTokenAvailable) {
        Write-Host "incidentFilters (response plans): $ifCount"
        foreach ($filter in $incidentFilters) {
            $name = $filter.metadata.name
            $spec = $filter.spec

            $customInstructions = $spec.customInstructions

            # Build filter properties
            $platform = if ($spec.incidentPlatform) { $spec.incidentPlatform }
                        elseif ($spec.platformType) { $spec.platformType }
                        else { "AzureMonitor" }
            $handling = if ($spec.handlingAgent -and $spec.handlingAgent -ne "") { $spec.handlingAgent } else { "default" }

            $propsObj = $spec.PSObject.Copy()
            $propsObj.PSObject.Properties.Remove('customInstructions')
            $propsObj | Add-Member -NotePropertyName 'incidentPlatform' -NotePropertyValue $platform -Force
            $propsObj | Add-Member -NotePropertyName 'handlingAgent' -NotePropertyValue $handling -Force
            $propsObj | Add-Member -NotePropertyName 'isEnabled' -NotePropertyValue $true -Force

            # Data-plane PUT with retry — platform init may still be in progress
            $filterOk = $false
            for ($attempt = 1; $attempt -le 4; $attempt++) {
                try {
                    $token = Get-DpToken
                    $body = @{
                        name       = $name
                        type       = "IncidentFilter"
                        tags       = @()
                        properties = $propsObj
                    } | ConvertTo-Json -Compress -Depth 20
                    $encodedName = [uri]::EscapeDataString($name)
                    $headers = @{
                        Authorization  = "Bearer $token"
                        "Content-Type" = "application/json"
                    }
                    $null = Invoke-RestMethod -TimeoutSec 30 -Uri "$AgentEndpoint/api/v2/extendedAgent/incidentFilters/$encodedName" `
                        -Method Put -Headers $headers -Body $body -ContentType "application/json"
                    Write-Host "  data-plane PUT incidentFilters/$name"
                    Write-Host "    ok"
                    $filterOk = $true
                    break
                } catch {
                    if ($attempt -lt 4) {
                        Write-Host "  data-plane PUT incidentFilters/$name - retry $attempt/4 in 30s (platform init)..."
                        Start-Sleep -Seconds 30
                    } else {
                        Write-Host "  data-plane PUT incidentFilters/$name"
                        Write-Host "    FAILED"
                    }
                }
            }

            # Create incident handler if customInstructions is set (data-plane only)
            if ($customInstructions) {
                $handlerBody = @{
                    id                       = $name
                    name                     = ""
                    description              = ""
                    incidentFilterId         = $name
                    incidentProcessingGuide  = @()
                    tools                    = @()
                    incidents                = @()
                    customInstructions       = $customInstructions
                } | ConvertTo-Json -Compress -Depth 10
                Write-Host "  data-plane PUT incidentPlayground/handlers/$name"
                $handlerOk = $false
                for ($attempt = 1; $attempt -le 5; $attempt++) {
                    try {
                        $token = Get-DpToken
                        $headers = @{
                            Authorization  = "Bearer $token"
                            "Content-Type" = "application/json"
                        }
                        $resp = Invoke-WebRequest -TimeoutSec 30 -Uri "$AgentEndpoint/api/v1/incidentPlayground/handlers/$name" `
                            -Method Put -Headers $headers -Body $handlerBody -ContentType "application/json" `
                            -UseBasicParsing
                        $httpCode = $resp.StatusCode
                        if ($httpCode -ge 200 -and $httpCode -lt 300 -or $httpCode -eq 409) {
                            Write-Host "    ok (HTTP $httpCode)"
                            $handlerOk = $true
                            break
                        }
                    } catch {
                        $httpCode = 0
                        if ($_.Exception.Response) { $httpCode = [int]$_.Exception.Response.StatusCode }
                        if ($httpCode -eq 409) {
                            Write-Host "    ok (HTTP 409)"
                            $handlerOk = $true
                            break
                        }
                        Write-Host "    attempt $attempt/5: HTTP $httpCode, retrying in 15s..."
                        Start-Sleep -Seconds 15
                    }
                }
                if (-not $handlerOk) { Write-Host "    FAILED after 5 attempts" }
            }
        }
    } else {
        Write-Host "incidentFilters: $ifCount - WARNING skipped (no data-plane token)"
        foreach ($f in $incidentFilters) {
            $DpSkippedItems.Add("incidentFilter/$($f.metadata.name)")
        }
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# 1c. scheduledTasks — data-plane PUT
# Route: PUT /api/v2/extendedAgent/scheduledtasks/{name}
# ═════════════════════════════════════════════════════════════════════════════
$scheduledTasks = $extras.scheduledTasks
$stCount = ($scheduledTasks | Measure-Object).Count
if ($stCount -gt 0) {
    if ($DpTokenAvailable) {
        Write-Host "scheduledTasks: $stCount"
        foreach ($task in $scheduledTasks) {
            $name = $task.metadata.name
            $spec = $task.spec
            $props = @{
                name           = if ($spec.name) { $spec.name } else { "" }
                description    = if ($spec.description) { $spec.description } else { "" }
                cronExpression = if ($spec.schedule) { $spec.schedule } elseif ($spec.cronExpression) { $spec.cronExpression } else { "" }
                agentPrompt    = if ($spec.prompt) { $spec.prompt } elseif ($spec.agentPrompt) { $spec.agentPrompt } else { "" }
                agentMode      = if ($spec.mode) { $spec.mode } elseif ($spec.agentMode) { $spec.agentMode } else { "Review" }
                isEnabled      = if ($null -ne $spec.enabled) { $spec.enabled } else { $true }
            }
            DataPlane-PutExtended -Kind "scheduledtasks" -Name $name -Type "ScheduledTask" -Tags @() -Properties $props
        }
    } else {
        Write-Host "scheduledTasks: $stCount - WARNING skipped (no data-plane token)"
        foreach ($t in $scheduledTasks) {
            $DpSkippedItems.Add("scheduledTask/$($t.metadata.name)")
        }
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# 1d. githubDomains — data-plane PUT /api/v2/github/domains/{domain}
# Supports authType: Pat (github.com only) and GitHubApp (BYO App)
# ═════════════════════════════════════════════════════════════════════════════
$githubDomains = $extras.githubDomains
$ghDomainCount = ($githubDomains | Measure-Object).Count
$byoappDomains = @()
if ($ghDomainCount -gt 0) {
    if ($DpTokenAvailable) {
        Write-Host "githubDomains: $ghDomainCount"
        foreach ($ghd in $githubDomains) {
            $domain = if ($ghd.metadata) { $ghd.metadata.name } else { $ghd.name }
            $spec = if ($ghd.spec) { $ghd.spec } else { $ghd }
            $authType = if ($spec.authType) { $spec.authType } else { "Pat" }

            # Skip entries that are OAuth/empty — those use the normal OAuth sign-in flow
            if ([string]::IsNullOrWhiteSpace($authType) -or $authType -eq "OAuth") {
                Write-Host "  skip githubDomains/$domain (authType=$authType, using OAuth flow)"
                continue
            }
            # For GitHubApp entries, require clientId
            $clientId = $spec.clientId
            if ($authType -eq "GitHubApp" -and [string]::IsNullOrWhiteSpace($clientId)) {
                Write-Host "  skip githubDomains/$domain (GitHubApp but no clientId - set githubAppClientId)"
                continue
            }

            $byoappDomains += $domain
            $domainEncoded = $domain -replace '\.', '_'
            $token = Get-DpToken
            $specJson = $spec | ConvertTo-Json -Depth 10 -Compress
            try {
                $result = Invoke-RestMethod -Uri "$AgentEndpoint/api/v2/github/domains/$domainEncoded" `
                    -Method Put -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } `
                    -Body $specJson -ErrorAction Stop
                Write-Host "  ok githubDomains/$domain ($authType)"
            } catch {
                $errMsg = $_.Exception.Message
                try { $errMsg = ($_ | ConvertFrom-Json).message } catch {}
                Write-Host "  FAILED - PUT github/domains/$domainEncoded : $errMsg"
            }
        }
    } else {
        Write-Host "githubDomains: $ghDomainCount - WARNING skipped (no data-plane token)"
        foreach ($ghd in $githubDomains) {
            $gdn = if ($ghd.metadata) { $ghd.metadata.name } else { $ghd.name }
            $DpSkippedItems.Add("githubDomain/$gdn")
        }
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# 2. repos — data-plane only (requires azuresre.dev token)
# Split into byoapp_repos (domain has GitHubApp entry) and oauth_repos
# ═════════════════════════════════════════════════════════════════════════════
$repos = $extras.repos
$repoCount = ($repos | Measure-Object).Count
$oauthRepos = @()
$byoappRepos = @()
if ($repoCount -gt 0) {
    if ($DpTokenAvailable) {
        foreach ($repo in $repos) {
            $rurl = $repo.spec.url
            if ($rurl -match '^http') {
                $rdomain = ([System.Uri]$rurl).Host
            } else {
                $rdomain = "github.com"
            }
            if ($byoappDomains -contains $rdomain) {
                $byoappRepos += $repo
            } else {
                $oauthRepos += $repo.name
            }
        }
        if ($byoappRepos.Count -gt 0) {
            Write-Host "repos: $($byoappRepos.Count) via BYO App (will be wired after githubDomains)"
        }
        if ($oauthRepos.Count -gt 0) {
            Write-Host "repos: $($oauthRepos.Count) via OAuth (will be wired after GitHub sign-in below)"
        }
    } else {
        Write-Host "repos: $repoCount - WARNING skipped (no data-plane token)"
        foreach ($repo in $repos) {
            $DpSkippedItems.Add("repo/$($repo.name)")
        }
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# 3. repoInstructions (data-plane tar.gz, one per repo)
# ═════════════════════════════════════════════════════════════════════════════
$repoInstructions = $extras.repoInstructions
$riCount = ($repoInstructions | Measure-Object).Count
if ($riCount -gt 0) {
    if ($DpTokenAvailable) {
        Write-Host "repoInstructions: $riCount"
        foreach ($ri in $repoInstructions) {
            $repo = $ri.repo
            $files = @($ri.files)
            $encodedRepo = [uri]::EscapeDataString($repo)
            $url = "$AgentEndpoint/api/v1/WorkspaceMemory/repo-instructions?repo=$encodedRepo"
            DataPlane-UploadTarball -Label "repo-instructions/$repo" -Url $url -FilesArray $files
        }
    } else {
        Write-Host "repoInstructions: $riCount - WARNING skipped (no data-plane token)"
        $DpSkippedItems.Add("repoInstructions ($riCount items)")
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# 4. knowledge — AgentMemory multipart upload (data-plane only)
# ═════════════════════════════════════════════════════════════════════════════
$knowledge = $extras.knowledge
$kCount = ($knowledge | Measure-Object).Count
if ($kCount -gt 0) {
    if ($DpTokenAvailable) {
        Write-Host "knowledge: $kCount file(s)"
        $url = "$AgentEndpoint/api/v1/AgentMemory/upload"
        for ($i = 0; $i -lt $kCount; $i++) {
            $k = $knowledge[$i]
            $fname = $k.filename
            $mime = if ($k.mimeType) { $k.mimeType } else { "application/octet-stream" }
            $trig = if ($null -ne $k.triggerIndexing) { $k.triggerIndexing.ToString().ToLower() } else { "true" }
            $lpath = $k.localPath
            if ($lpath) {
                if (-not (Test-Path $lpath)) {
                    Write-Host "    FAILED - localPath not found: $lpath"
                    continue
                }
                DataPlane-UploadMultipart -Label "knowledge#$i" -Url $url -Filename $fname -Mime $mime -Trigger $trig -SrcPath $lpath
            } else {
                $tmpf = [System.IO.Path]::GetTempFileName()
                try {
                    $content = if ($k.content) { $k.content } else { "" }
                    Set-Content -Path $tmpf -Value $content -NoNewline
                    DataPlane-UploadMultipart -Label "knowledge#$i" -Url $url -Filename $fname -Mime $mime -Trigger $trig -SrcPath $tmpf
                } finally {
                    Remove-Item $tmpf -ErrorAction SilentlyContinue
                }
            }
        }
    } else {
        Write-Host "knowledge: $kCount file(s) - WARNING skipped (no data-plane token)"
        $DpSkippedItems.Add("knowledge ($kCount files)")
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# 4a-2. knowledgeItems — ARM PUT as KnowledgeFile connectors
# ═════════════════════════════════════════════════════════════════════════════
$knowledgeItems = $extras.knowledgeItems
$kiCount = ($knowledgeItems | Measure-Object).Count
if ($kiCount -gt 0) {
    Write-Host "knowledgeItems: $kiCount file(s) -> Knowledge Sources (ARM)"
    for ($i = 0; $i -lt $kiCount; $i++) {
        $ki = $knowledgeItems[$i]
        $fname = $ki.name
        $content = $ki.content
        if ([string]::IsNullOrEmpty($content)) {
            Write-Host "  skip $fname (no content)"
            continue
        }
        $sanitized = ($fname.ToLower() -replace '[^a-z0-9-]', '-') -replace '-+', '-' -replace '^-|-$', ''
        $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($content))
        $ctype = switch -Regex ($fname) {
            '\.md$'   { "text/markdown" }
            '\.txt$'  { "text/plain" }
            '\.pdf$'  { "application/pdf" }
            '\.json$' { "application/json" }
            default   { "application/octet-stream" }
        }
        $body = @{
            properties = @{
                dataConnectorType  = "KnowledgeFile"
                dataSource         = $sanitized
                extendedProperties = @{
                    displayName = $fname
                    fileName    = $fname
                    fileContent = $b64
                    contentType = $ctype
                }
            }
        } | ConvertTo-Json -Compress -Depth 10
        Arm-PutConnector -Name $sanitized -BodyJson $body
        # KnowledgeFile connectors need 15s between PUTs to avoid 500s
        if ($i -lt ($kiCount - 1)) { Start-Sleep -Seconds 15 }
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# 4a-3. synthesizedKnowledge — tar.gz upload to WorkspaceMemory (data-plane)
# ═════════════════════════════════════════════════════════════════════════════
$synthDir = $extras.synthesizedKnowledgeDir
if ($synthDir -and (Test-Path $synthDir -PathType Container)) {
    $skFiles = Get-ChildItem -Path $synthDir -File -Recurse
    $skCount = $skFiles.Count
    if ($skCount -gt 0) {
        if ($DpTokenAvailable) {
            Write-Host "synthesizedKnowledge: $skCount file(s)"
            $tarball = Join-Path ([System.IO.Path]::GetTempPath()) "synth-$([guid]::NewGuid()).tar.gz"
            try {
                tar -czf $tarball -C $synthDir .
                $token = Get-DpToken
                Write-Host "  data-plane POST WorkspaceMemory/synthesized-knowledge ($skCount files)"
                $headers = @{
                    Authorization  = "Bearer $token"
                    "Content-Type" = "application/gzip"
                }
                $bytes = [System.IO.File]::ReadAllBytes($tarball)
                $null = Invoke-RestMethod -TimeoutSec 30 -Uri "$AgentEndpoint/api/v1/WorkspaceMemory/synthesized-knowledge" `
                    -Method Post -Headers $headers -Body $bytes
                Write-Host "    ok"
            } catch {
                Write-Host "    FAILED"
            } finally {
                Remove-Item $tarball -Force -ErrorAction SilentlyContinue
            }
        } else {
            Write-Host "synthesizedKnowledge: $skCount file(s) - WARNING skipped (no data-plane token)"
            $DpSkippedItems.Add("synthesizedKnowledge ($skCount files)")
        }
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# 4b. plugins.marketplaces (data-plane v2)
# ═════════════════════════════════════════════════════════════════════════════
$marketplaces = $extras.plugins.marketplaces
$mpCount = ($marketplaces | Measure-Object).Count
if ($mpCount -gt 0) {
    if ($DpTokenAvailable) {
        Write-Host "plugins.marketplaces: $mpCount"
        $url = "$AgentEndpoint/api/v2/plugins/marketplaces"
        foreach ($mp in $marketplaces) {
            $body = @{ metadata = @{ name = $mp.name }; spec = $mp.spec }
            DataPlane-PostJson -Label "marketplaces/$($mp.name)" -Url $url -BodyObj $body
        }
    } else {
        Write-Host "plugins.marketplaces: $mpCount - WARNING skipped (no data-plane token)"
        $DpSkippedItems.Add("plugins.marketplaces ($mpCount items)")
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# 4c. plugins.installations (data-plane v2)
# ═════════════════════════════════════════════════════════════════════════════
$installations = $extras.plugins.installations
$piCount = ($installations | Measure-Object).Count
if ($piCount -gt 0) {
    if ($DpTokenAvailable) {
        Write-Host "plugins.installations: $piCount"
        $url = "$AgentEndpoint/api/v2/plugins/installations"
        foreach ($inst in $installations) {
            $body = @{ metadata = @{ name = $inst.name }; spec = $inst.spec }
            DataPlane-PostJson -Label "installations/$($inst.name)" -Url $url -BodyObj $body
        }
    } else {
        Write-Host "plugins.installations: $piCount - WARNING skipped (no data-plane token)"
        $DpSkippedItems.Add("plugins.installations ($piCount items)")
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# 4d. hooks — data-plane only (no ARM sub-resource)
# ═════════════════════════════════════════════════════════════════════════════
$hooks = $extras.hooks
$hkCount = ($hooks | Measure-Object).Count
if ($hkCount -gt 0) {
    if ($DpTokenAvailable) {
        Process-ExtendedItems -JqKey "hooks" -Kind "hooks" -Items $hooks
    } else {
        Write-Host "hooks: $hkCount - WARNING skipped (no data-plane token)"
        foreach ($h in $hooks) {
            $DpSkippedItems.Add("hook/$($h.name)")
        }
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# 4e. commonPrompts — data-plane PUT
# Route: PUT /api/v2/extendedAgent/commonprompts/{name}
# ═════════════════════════════════════════════════════════════════════════════
$commonPrompts = $extras.commonPrompts
$cpCount = ($commonPrompts | Measure-Object).Count
if ($cpCount -gt 0) {
    if ($DpTokenAvailable) {
        Process-ExtendedItems -JqKey "commonPrompts" -Kind "commonprompts" -Items $commonPrompts
    } else {
        Write-Host "commonPrompts: $cpCount - WARNING skipped (no data-plane token)"
        foreach ($cp in $commonPrompts) {
            $DpSkippedItems.Add("commonPrompt/$($cp.name)")
        }
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# 4f. pluginConfigs — data-plane only
# ═════════════════════════════════════════════════════════════════════════════
$pluginConfigs = if ($extras.PSObject.Properties['pluginConfigs']) { $extras.pluginConfigs } else { $null }
$pcCount = ($pluginConfigs | Measure-Object).Count
if ($pcCount -gt 0) {
    if ($DpTokenAvailable) {
        Process-ExtendedItems -JqKey "pluginConfigs" -Kind "plugins" -Items $pluginConfigs
    } else {
        Write-Host "pluginConfigs: $pcCount - WARNING skipped (no data-plane token)"
        $DpSkippedItems.Add("pluginConfigs ($pcCount items)")
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# 4g-1. skills — data-plane PUT
# Route: PUT /api/v2/extendedAgent/skills/{name}
# ═════════════════════════════════════════════════════════════════════════════
$skillItems = if ($extras.PSObject.Properties['skills']) { $extras.skills } else { $null }
$skCount = ($skillItems | Measure-Object).Count
if ($skCount -gt 0) {
    if ($DpTokenAvailable) {
        Write-Host "skills: $skCount"
        foreach ($sk in $skillItems) {
            $name = if ($sk.metadata) { $sk.metadata.name } else { $sk.name }
            $spec = if ($sk.spec) { $sk.spec } else { $sk.properties }
            $props = @{
                name            = if ($spec.name) { $spec.name } else { $name }
                description     = if ($spec.description) { $spec.description } else { "" }
                tools           = if ($spec.tools) { @($spec.tools) } else { @() }
                skillContent    = if ($spec.skillContent) { $spec.skillContent } else { "" }
                additionalFiles = if ($spec.additionalFiles) { @($spec.additionalFiles) } else { @() }
            }
            DataPlane-PutExtended -Kind "skills" -Name $name -Type "Skill" -Tags @() -Properties $props
        }
    } else {
        Write-Host "skills: $skCount - WARNING skipped (no data-plane token)"
        foreach ($sk in $skillItems) {
            $skName = if ($sk.metadata) { $sk.metadata.name } else { $sk.name }
            $DpSkippedItems.Add("skill/$skName")
        }
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# 4g-2. subagents — data-plane PUT
# Route: PUT /api/v2/extendedAgent/agents/{name}
# ═════════════════════════════════════════════════════════════════════════════
$subagentItems = if ($extras.PSObject.Properties['subagents']) { $extras.subagents } else { $null }
$saCount = ($subagentItems | Measure-Object).Count
if ($saCount -gt 0) {
    if ($DpTokenAvailable) {
        Write-Host "subagents: $saCount"
        foreach ($sa in $subagentItems) {
            $name = if ($sa.metadata) { $sa.metadata.name } else { $sa.name }
            $props = if ($sa.spec) { $sa.spec } else { $sa.properties }
            DataPlane-PutExtended -Kind "agents" -Name $name -Type "ExtendedAgent" -Tags @() -Properties $props
        }
    } else {
        Write-Host "subagents: $saCount - WARNING skipped (no data-plane token)"
        foreach ($sa in $subagentItems) {
            $saName = if ($sa.metadata) { $sa.metadata.name } else { $sa.name }
            $DpSkippedItems.Add("subagent/$saName")
        }
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# 4g-3. tools — data-plane PUT
# Route: PUT /api/v2/extendedAgent/tools/{name}
# ═════════════════════════════════════════════════════════════════════════════
$toolItems = if ($extras.PSObject.Properties['tools']) { $extras.tools } else { $null }
$tlCount = ($toolItems | Measure-Object).Count
if ($tlCount -gt 0) {
    if ($DpTokenAvailable) {
        Write-Host "tools: $tlCount"
        foreach ($tl in $toolItems) {
            $name = if ($tl.metadata) { $tl.metadata.name } else { $tl.name }
            $props = if ($tl.spec) { $tl.spec } else { $tl.properties }
            DataPlane-PutExtended -Kind "tools" -Name $name -Type "Tool" -Tags @() -Properties $props
        }
    } else {
        Write-Host "tools: $tlCount - WARNING skipped (no data-plane token)"
        foreach ($tl in $toolItems) {
            $tlName = if ($tl.metadata) { $tl.metadata.name } else { $tl.name }
            $DpSkippedItems.Add("tool/$tlName")
        }
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# 4g. httpTriggers — data-plane only
# ═════════════════════════════════════════════════════════════════════════════
$httpTriggers = $extras.httpTriggers
$htCount = ($httpTriggers | Measure-Object).Count
$HttpTriggerUrl = ""
if ($htCount -gt 0) {
    if ($DpTokenAvailable) {
        Write-Host "httpTriggers: $htCount"
        $token = Get-DpToken
        $headers = @{ Authorization = "Bearer $token" }
        try {
            $existingTriggers = Invoke-RestMethod -TimeoutSec 30 -Uri "$AgentEndpoint/api/v1/httpTriggers" -Headers $headers
        } catch {
            $existingTriggers = @()
        }
        foreach ($ht in $httpTriggers) {
            $name = $ht.name
            $spec = if ($ht.spec) { $ht.spec } else { $ht }
            $body = @{ name = $name } 
            # Merge spec properties into body
            if ($spec.PSObject) {
                foreach ($p in $spec.PSObject.Properties) {
                    $body[$p.Name] = $p.Value
                }
            }
            $bodyJson = $body | ConvertTo-Json -Compress -Depth 20

            # Check if trigger already exists
            $existingId = ($existingTriggers | Where-Object { $_.name -eq $name } | Select-Object -First 1).id
            if ($existingId) {
                $existingUrl = "$AgentEndpoint/api/v1/httptriggers/trigger/$existingId"
                Write-Host "  httpTrigger/${name}: $existingUrl"
                if (-not $HttpTriggerUrl) { $HttpTriggerUrl = $existingUrl }
            } else {
                try {
                    $resp = Invoke-RestMethod -TimeoutSec 30 -Uri "$AgentEndpoint/api/v1/httptriggers/create" `
                        -Method Post -Headers $headers -Body $bodyJson -ContentType "application/json"
                    $triggerUrl = if ($resp.triggerUrl) { $resp.triggerUrl } else { "created" }
                    Write-Host "  httpTrigger/${name}: $triggerUrl"
                    if (-not $HttpTriggerUrl) { $HttpTriggerUrl = $triggerUrl }
                } catch {
                    $httpCode = 0
                    if ($_.Exception.Response) { $httpCode = [int]$_.Exception.Response.StatusCode }
                    Write-Host "  httpTrigger/${name}: FAILED (HTTP $httpCode)"
                }
            }
        }
    } else {
        Write-Host "httpTriggers: $htCount - WARNING skipped (no data-plane token)"
        foreach ($ht in $httpTriggers) {
            $DpSkippedItems.Add("httpTrigger/$($ht.name)")
        }
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# 4h. MCP connectors — ARM PUT (native properties, no data-plane token needed)
# ═════════════════════════════════════════════════════════════════════════════
$connectors = $extras.connectors
$cnCount = ($connectors | Measure-Object).Count
if ($cnCount -gt 0) {
    Write-Host "connectors: $cnCount (ARM)"
    foreach ($c in $connectors) {
        $cname = $c.name
        $body = @{ properties = $c.properties } | ConvertTo-Json -Compress -Depth 20
        Arm-PutConnector -Name $cname -BodyJson $body
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# 4i. Webhook bridge Logic App — auto-deploy if httpTriggers exist and
#     enableWebhookBridge is set.
# ═════════════════════════════════════════════════════════════════════════════
if ($HttpTriggerUrl) {
    $agentJsonDir = Split-Path $ExtrasFile -Parent
    $whEnabled = $false
    $candidates = @(
        (Join-Path (Split-Path $agentJsonDir -Parent) "agent.json"),
        (Join-Path $agentJsonDir "agent.json")
    )
    if ($env:INPUT) { $candidates = @(Join-Path $env:INPUT "agent.json") + $candidates }
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            try {
                $agentJson = Get-Content -Raw $candidate | ConvertFrom-Json
                $whEnabled = $agentJson.toggles.enableWebhookBridge -eq $true
            } catch { }
            break
        }
    }

    if ($whEnabled) {
        # Check if Logic App already exists
        $existingLa = az resource list -g $ResourceGroup --resource-type Microsoft.Logic/workflows `
            --query "[?name=='$AgentName-webhook-bridge'].name" -o tsv 2>$null
        if ($existingLa) {
            $whCallback = az rest --method POST `
                --url "/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.Logic/workflows/$AgentName-webhook-bridge/triggers/incoming_webhook/listCallbackUrl?api-version=2019-05-01" `
                --query value -o tsv 2>$null
            Write-Host ""
            Write-Host "webhook-bridge: already exists"
            Write-Host "  Callback URL: $whCallback"
        } else {
            Write-Host ""
            Write-Host "-- Deploying webhook bridge Logic App --"
            Write-Host "  Trigger URL: $HttpTriggerUrl"
            $scriptPath = $PSScriptRoot
            # Look for bicep template relative to this script (../../bicep/logic-app-bridge.bicep)
            $bicepPath = Join-Path (Split-Path (Split-Path $scriptPath -Parent) -Parent) "bicep" "logic-app-bridge.bicep"
            $location = az group show -n $ResourceGroup --query location -o tsv 2>$null
            try {
                $laResultRaw = az deployment group create `
                    --resource-group $ResourceGroup `
                    --template-file $bicepPath `
                    --parameters agentName=$AgentName location=$location triggerUrl=$HttpTriggerUrl `
                    --output json 2>&1
                $laResult = $laResultRaw | ConvertFrom-Json
                $laState = $laResult.properties.provisioningState
                if ($laState -eq "Succeeded") {
                    $whCallback = $laResult.properties.outputs.logicAppCallbackUrl.value
                    Write-Host "  Webhook bridge deployed"
                    Write-Host "  Callback URL: $whCallback"
                } else {
                    Write-Host "  Webhook bridge deployment failed"
                    $laResultRaw | Select-Object -First 10 | Write-Host
                }
            } catch {
                Write-Host "  Webhook bridge deployment failed"
                Write-Host "  $($_.Exception.Message)"
            }
        }
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# 5. Post-deploy auth wiring (data-plane). All optional — driven by env vars.
# ═════════════════════════════════════════════════════════════════════════════
if ($DpTokenAvailable) {

    # 5a. GitHub auth
    if ($env:GITHUB_PAT) {
        Write-Host "GitHub auth: installing PAT (no browser needed)"
        try {
            $token = Get-DpToken
            $headers = @{
                Authorization  = "Bearer $token"
                "Content-Type" = "application/json"
            }
            $body = @{ accessToken = $env:GITHUB_PAT } | ConvertTo-Json -Compress
            $null = Invoke-RestMethod -TimeoutSec 30 -Uri "$AgentEndpoint/api/v1/Github/auth/pat" `
                -Method Post -Headers $headers -Body $body -ContentType "application/json"
            Write-Host "  ok"
        } catch {
            Write-Host "  FAILED - POST /api/v1/Github/auth/pat"
        }
    } elseif ($oauthRepos.Count -gt 0) {
        Write-Host "GitHub auth: will use OAuth (browser sign-in) - see URL below"
    }

    # 5b. Azure DevOps PAT
    if ($env:ADO_PAT -and $env:ADO_ORG) {
        Write-Host "post_deploy: ADO PAT detected - wiring up for $($env:ADO_ORG)"
        try {
            $token = Get-DpToken
            $headers = @{
                Authorization  = "Bearer $token"
                "Content-Type" = "application/json"
            }
            $body = @{ accessToken = $env:ADO_PAT } | ConvertTo-Json -Compress
            $null = Invoke-RestMethod -TimeoutSec 30 -Uri "$AgentEndpoint/api/v1/AzureDevOps/auth/pat?organization=$($env:ADO_ORG)" `
                -Method Post -Headers $headers -Body $body -ContentType "application/json"
            Write-Host "  ok"
        } catch {
            Write-Host "  FAILED - POST /api/v1/AzureDevOps/auth/pat"
        }
    }

    # 5c. Azure DevOps via AAD
    if ($env:ADO_USE_AAD -eq "1" -and $env:ADO_ORG) {
        Write-Host "post_deploy: wiring ADO via your AAD token for $($env:ADO_ORG)"
        try {
            $aadToken = az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv 2>$null
            $token = Get-DpToken
            $headers = @{
                Authorization  = "Bearer $token"
                "Content-Type" = "application/json"
            }
            $body = @{ aadAccessToken = $aadToken } | ConvertTo-Json -Compress
            $null = Invoke-RestMethod -TimeoutSec 30 -Uri "$AgentEndpoint/api/v1/AzureDevOps/aadauth/complete?organization=$($env:ADO_ORG)" `
                -Method Post -Headers $headers -Body $body -ContentType "application/json"
            Write-Host "  ok"
        } catch {
            Write-Host "  FAILED - POST /api/v1/AzureDevOps/aadauth/complete"
        }
    }

    # 5d. Azure DevOps via Managed Identity
    if ($env:ADO_USE_MI -eq "1" -and $env:ADO_ORG) {
        Write-Host "post_deploy: wiring ADO via agent MI for $($env:ADO_ORG)"
        try {
            $token = Get-DpToken
            $headers = @{ Authorization = "Bearer $token" }
            $null = Invoke-RestMethod -TimeoutSec 30 -Uri "$AgentEndpoint/api/v1/AzureDevOps/auth/mi?organization=$($env:ADO_ORG)" `
                -Method Post -Headers $headers
            Write-Host "  ok"
        } catch {
            Write-Host "  FAILED - POST /api/v1/AzureDevOps/auth/mi"
        }
    }

    Write-Host ""

    # ─────────────────────────────────────────────────────────────────────────
    # BYO App repos — push repos that use GitHubApp auth directly (no OAuth needed)
    # ─────────────────────────────────────────────────────────────────────────
    if ($byoappRepos.Count -gt 0) {
        Write-Host "byoapp repos: $($byoappRepos.Count)"
        $token = Get-DpToken
        foreach ($repo in $byoappRepos) {
            $rname = $repo.name
            $rurl = $repo.spec.url
            if ($rurl -notmatch '^http' -and $rurl -match '/') {
                $rurl = "https://github.com/$rurl"
            }
            $rtypeIn = if ($repo.spec.type) { $repo.spec.type } else { "github" }
            $rtype = switch -Regex ($rtypeIn.ToLower()) {
                'ado|azuredevops' { "AzureDevOps" }
                default { "GitHub" }
            }
            $rdesc = if ($repo.spec.description) { $repo.spec.description } else { "" }
            $rbody = @{ name = $rname; type = "CodeRepo"; properties = @{ url = $rurl; type = $rtype } }
            if ($rdesc) { $rbody.properties.description = $rdesc }
            $rbodyJson = $rbody | ConvertTo-Json -Depth 5 -Compress
            try {
                $null = Invoke-RestMethod -Uri "$AgentEndpoint/api/v2/repos/$([Uri]::EscapeDataString($rname))" `
                    -Method Put -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } `
                    -Body $rbodyJson -ErrorAction Stop
                Write-Host "  ok repo/$rname ($rurl) [BYO App]"
            } catch {
                Write-Host "  FAILED - PUT /api/v2/repos/$rname (try the portal Repos blade)"
            }
        }
    }

    # ─────────────────────────────────────────────────────────────────────────
    # GitHub: OAuth sign-in + connector + repo wiring.
    # ─────────────────────────────────────────────────────────────────────────
    if ($oauthRepos.Count -gt 0) {
        try { $token = Get-DpToken } catch { $token = $null }
        $ghConfigured = $false
        if ($token) {
            try {
                $headers = @{ Authorization = "Bearer $token" }
                $ghStatus = Invoke-RestMethod -TimeoutSec 30 -Uri "$AgentEndpoint/api/v1/Github/auth/status" -Headers $headers
                $ghConfigured = ($ghStatus.isConfigured -eq $true) -or ($ghStatus.hosts[0].isConfigured -eq $true)
            } catch { }
        }

        # Shared identity + connector body (used in both fast-path and OAuth wait)
        $ident = if ($AgentUami) { $AgentUami } else {
            Write-Host "  WARN: agent has no user-assigned MI; falling back to SystemAssigned."
            "SystemAssigned"
        }
        $connBody = @{
            name       = "github"
            type       = "AgentConnector"
            properties = @{
                dataConnectorType = "GitHubOAuth"
                dataSource        = "github-oauth"
                identity          = $ident
            }
        } | ConvertTo-Json -Compress -Depth 10

        $connectorOk = $false

        # Fast path: if auth/status says configured (or PAT), try the connector PUT immediately
        if ($ghConfigured -or $env:GITHUB_PAT) {
            Write-Host "-- Wiring GitHub connector + repos --"
            try {
                $token = Get-DpToken
                $headers = @{
                    Authorization  = "Bearer $token"
                    "Content-Type" = "application/json"
                }
                $null = Invoke-RestMethod -TimeoutSec 30 -Uri "$AgentEndpoint/api/v2/extendedAgent/connectors/github" `
                    -Method Put -Headers $headers -Body $connBody -ContentType "application/json"
                # Verify the connector is actually healthy (not just metadata)
                Start-Sleep -Seconds 3
                try {
                    $connCheck = Invoke-RestMethod -TimeoutSec 30 -Uri "$AgentEndpoint/api/v2/extendedAgent/connectors/github" `
                        -Method Get -Headers @{ Authorization = "Bearer $token" }
                    $provState = $connCheck.properties.provisioningState
                    if ($provState -eq 'Succeeded') {
                        Write-Host "  ok connector/github (GitHubOAuth, identity=$($ident.Split('/')[-1]))"
                        $connectorOk = $true
                    } else {
                        Write-Host "  WARN: connector created but state=$provState — falling back to OAuth wait..."
                    }
                } catch {
                    Write-Host "  ok connector/github (GitHubOAuth, identity=$($ident.Split('/')[-1]))"
                    $connectorOk = $true
                }
            } catch {
                Write-Host "  WARN: connector PUT failed (stale auth?) — falling back to OAuth wait..."
            }
        }

        # OAuth wait: if connector not yet created, show URL and poll until user completes auth
        if (-not $connectorOk -and -not $env:GITHUB_PAT) {
            Write-Host "-- GitHub OAuth sign-in required --"
            Write-Host "Repos waiting: $($oauthRepos -join ' ')"
            $oauthUrl = $null
            try { $token = Get-DpToken } catch { $token = $null }
            if ($token) {
                try {
                    $headers = @{ Authorization = "Bearer $token" }
                    $ghConfig = Invoke-RestMethod -TimeoutSec 30 -Uri "$AgentEndpoint/api/v1/Github/config" -Headers $headers
                    $oauthUrl = if ($ghConfig.oAuthUrl) { $ghConfig.oAuthUrl } elseif ($ghConfig.OAuthUrl) { $ghConfig.OAuthUrl } else { $null }
                } catch { }
            }
            if ($oauthUrl) {
                Write-Host "  1. Open this URL in a browser:"
                Write-Host "     $oauthUrl"
                Write-Host "  2. Sign in to GitHub and approve the SRE Agent app."
                Write-Host ""
                Write-Host "  Waiting for GitHub authorization (Ctrl-C to skip)..."
                for ($attempt = 1; $attempt -le 24; $attempt++) {
                    Start-Sleep -Seconds 10
                    try {
                        $token = Get-DpToken
                        $headers = @{
                            Authorization  = "Bearer $token"
                            "Content-Type" = "application/json"
                        }
                        # Check auth/status — only trust isConfigured, not connector PUT success
                        $ghCheck = Invoke-RestMethod -TimeoutSec 30 -Uri "$AgentEndpoint/api/v1/Github/auth/status" -Headers $headers
                        $isAuth = ($ghCheck.isConfigured -eq $true) -or ($ghCheck.hosts -and $ghCheck.hosts[0].isConfigured -eq $true)
                        if ($isAuth) {
                            $null = Invoke-RestMethod -TimeoutSec 30 -Uri "$AgentEndpoint/api/v2/extendedAgent/connectors/github" `
                                -Method Put -Headers $headers -Body $connBody -ContentType "application/json"
                            Write-Host "  GitHub authorized!"
                            Write-Host "  ok connector/github"
                            $connectorOk = $true
                            break
                        }
                    } catch { }
                    Write-Host "  ... waiting ($($attempt * 10)/240s)" -NoNewline
                    Write-Host "`r" -NoNewline
                }
                Write-Host ""
                if (-not $connectorOk) {
                    Write-Host "  Timed out. Re-run Apply-Extras after authorizing."
                    Write-Host "  Headless alternative: `$env:GITHUB_PAT='ghp_xxx' && re-run"
                }
            } else {
                Write-Host "  Could not fetch OAuth URL from $AgentEndpoint/api/v1/Github/config."
                Write-Host "  Fallback: Azure portal -> agent -> Repos -> 'Authorize' next to each repo."
            }
        }

        # Wire repos (only if connector succeeded)
        if ($connectorOk) {
            Write-Host "-- Wiring GitHub repos --"
            $token = Get-DpToken
            $headers = @{
                Authorization  = "Bearer $token"
                "Content-Type" = "application/json"
            }
            foreach ($repo in $repos) {
                $rname = $repo.name
                $rurl = $repo.spec.url
                if ($rurl -and $rurl -notmatch '^https?://' -and $rurl -match '/') {
                    $rurl = "https://github.com/$rurl"
                }
                $rtypeIn = if ($repo.spec.type) { $repo.spec.type } else { "github" }
                $rtype = switch -Regex ($rtypeIn.ToLower()) {
                    '^(ado|azuredevops|azure-devops)$' { "AzureDevOps" }
                    default { "GitHub" }
                }
                $rdesc = if ($repo.spec.description) { $repo.spec.description } else { "" }
                $rProps = @{ url = $rurl; type = $rtype }
                if ($rdesc) { $rProps.description = $rdesc }
                $rbody = @{
                    name       = $rname
                    type       = "CodeRepo"
                    properties = $rProps
                } | ConvertTo-Json -Compress -Depth 10
                $encodedRname = [uri]::EscapeDataString($rname)
                try {
                    $null = Invoke-RestMethod -TimeoutSec 30 -Uri "$AgentEndpoint/api/v2/repos/$encodedRname" `
                        -Method Put -Headers $headers -Body $rbody -ContentType "application/json"
                    Write-Host "  ok repo/$rname ($rurl)"
                } catch {
                    Write-Host "  FAILED - PUT /api/v2/repos/$rname (try the portal Repos blade)"
                }
            }
            Write-Host ""
        }
    }

    if (-not $env:ADO_PAT -and $env:ADO_USE_AAD -ne "1" -and $env:ADO_USE_MI -ne "1") {
        Write-Host "Optional Azure DevOps auth (only needed if you have ADO repos / connectors):"
        Write-Host "  PAT:  `$env:ADO_ORG='https://dev.azure.com/<org>'; `$env:ADO_PAT='<pat>'; re-run"
        Write-Host "  AAD:  `$env:ADO_ORG='https://dev.azure.com/<org>'; `$env:ADO_USE_AAD='1'; re-run"
        Write-Host "  MI:   `$env:ADO_ORG='https://dev.azure.com/<org>'; `$env:ADO_USE_MI='1';  re-run"
        Write-Host ""
    }
}  # end DpTokenAvailable block

# ═════════════════════════════════════════════════════════════════════════════
# Summary of skipped items (data-plane token unavailable)
# ═════════════════════════════════════════════════════════════════════════════
if ($DpSkippedItems.Count -gt 0) {
    Write-Host ""
    Write-Host "================================================================"
    Write-Host "  WARNING: $($DpSkippedItems.Count) item(s) skipped (no data-plane token)"
    Write-Host "  These require audience https://azuresre.dev which is not"
    Write-Host "  available in this environment (Cloud Shell MSI)."
    Write-Host ""
    Write-Host "  To apply the remaining items:"
    Write-Host "    1. From a compliant machine: az login && re-run this script"
    Write-Host "    2. Or configure in the portal: https://sre.azure.com"
    Write-Host ""
    Write-Host "  Skipped:"
    foreach ($item in $DpSkippedItems) {
        Write-Host "    - $item"
    }
    Write-Host "================================================================"
}

Write-Host ""
Write-Host "-- Your agent --"
Write-Host "  Open agent:     https://sre.azure.com/#/agent/$Subscription/$ResourceGroup/$AgentName"
Write-Host "  Resource group: https://portal.azure.com/#@/resource/subscriptions/$Subscription/resourceGroups/$ResourceGroup/overview"
Write-Host "  Data plane:     $AgentEndpoint"
Write-Host ""
Write-Host "Done."
