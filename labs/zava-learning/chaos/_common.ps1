<#
.SYNOPSIS
  Shared helpers for the Zava Learning chaos scripts (break-*.ps1 / fix-*.ps1 / reset.ps1).

  The chaos model is deliberately realistic:
    * IaC-param faults flip infra/main.parameters.json, push the bad desired state,
      AND apply the live Azure change.
    * Backend-state faults (DB drift, role state, secret rotation) change live state
      only; reset/fix restores that live operational drift.
#>
$ErrorActionPreference = "Stop"

$script:RepoRoot  = Split-Path -Parent $PSScriptRoot
$script:ParamFile = Join-Path $RepoRoot "infra\main.parameters.json"
$script:EnvFile   = Join-Path $RepoRoot "sre-config\.env"

function Get-ResourceToken {
  param([Parameter(Mandatory)][string]$ResourceGroup)
  $nsg = az network nsg list -g $ResourceGroup --query "[?starts_with(name,'nsg-aca-')].name | [0]" -o tsv
  if (-not $nsg) { throw "Could not locate the Container Apps NSG (nsg-aca-*) in $ResourceGroup." }
  return ($nsg -replace '^nsg-aca-', '')
}

function Get-RgLocation {
  param([Parameter(Mandatory)][string]$ResourceGroup)
  return (az group show -g $ResourceGroup --query location -o tsv)
}

function Get-EnvName {
  # rg-zava-learning-<env>  ->  <env>
  param([Parameter(Mandatory)][string]$ResourceGroup)
  return ($ResourceGroup -replace '^rg-zava-learning-', '')
}

function Get-EnvFileValue {
  param([Parameter(Mandatory)][string]$Key)
  if (-not (Test-Path $script:EnvFile)) { return $null }
  $line = Select-String -Path $script:EnvFile -Pattern "^\s*$Key\s*=" -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $line) { return $null }
  return ($line.Line -replace "^\s*$Key\s*=\s*", '').Trim().Trim('"')
}

function Set-ParamLine {
  param(
    [Parameter(Mandatory)][string]$Pattern,
    [Parameter(Mandatory)][string]$Replacement
  )
  Invoke-WithRepoLock {
    $content = Get-Content -Raw $script:ParamFile
    if ($content -match [regex]::Escape($Replacement)) { return $false }
    $new = [regex]::Replace($content, $Pattern, $Replacement)
    if ($new -eq $content) { throw "Param pattern not found in $($script:ParamFile): $Pattern" }
    Set-Content -Path $script:ParamFile -Value $new -NoNewline
    return $true
  }
}

function Invoke-WithRepoLock {
  # Serialize repo mutations across concurrently-running chaos scripts (e.g. the demo's
  # "run ALL in parallel" launch, which spawns one process per scenario). Without this,
  # concurrent param edits + git commit/push race and corrupt infra/main.parameters.json
  # (two documents concatenated) and the git history. A session-local named mutex is enough
  # because the parallel tabs all run as the same user in the same session.
  param([Parameter(Mandatory)][scriptblock]$Action, [int]$TimeoutSec = 300)
  $mutex = New-Object System.Threading.Mutex($false, "ZavaChaosRepoLock")
  $held = $false
  try {
    try { $held = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSec)) }
    catch [System.Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { throw "Timed out waiting for the chaos repo lock." }
    & $Action
  } finally {
    if ($held) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
  }
}

function Invoke-WithAppGwLock {
  # Serialize App Gateway writes across concurrently-running chaos scripts. App Gateway only
  # accepts one write at a time; during the demo's "run ALL in parallel" launch, several lanes
  # (appgw / app / secret) issue gateway ops at once and all but one fail with "Another operation
  # is in progress" — silently, because the break used `-o none`. A session-local named mutex
  # serializes them so each lane's live mutation actually lands.
  param([Parameter(Mandatory)][scriptblock]$Action, [int]$TimeoutSec = 600)
  $mutex = New-Object System.Threading.Mutex($false, "ZavaChaosAppGwLock")
  $held = $false
  try {
    try { $held = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSec)) }
    catch [System.Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { throw "Timed out waiting for the chaos App Gateway lock." }
    & $Action
  } finally {
    if ($held) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
  }
}

function Set-AppGwProbePath {
  # Set a live App Gateway health-probe path and VERIFY it actually persisted, retrying under the
  # gateway lock. Returns $true only when the live probe reads back the expected path. Replaces the
  # old fire-and-forget `az ... probe update ... -o none`, which swallowed failures so a fault could
  # be "shipped" while the live gateway never changed (the endpoint stayed healthy the whole demo).
  param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$GatewayName,
    [Parameter(Mandatory)][string]$ProbeName,
    [Parameter(Mandatory)][string]$Path
  )
  $PSNativeCommandUseErrorActionPreference = $false
  Invoke-WithAppGwLock {
    for ($i = 1; $i -le 4; $i++) {
      az network application-gateway probe update `
        --resource-group $ResourceGroup --gateway-name $GatewayName `
        --name $ProbeName --path $Path -o none 2>$null
      $live = (az network application-gateway probe show `
        --resource-group $ResourceGroup --gateway-name $GatewayName `
        --name $ProbeName --query "path" -o tsv 2>$null)
      if ($live -eq $Path) { return $true }
      Start-Sleep -Seconds (2 * $i)
    }
    return $false
  }
}

function Set-IaCFault {
  # Atomically (cross-process) edit IaC param lines and/or stage pre-modified files, then
  # commit and push — the single safe path for shipping an IaC fault/fix to GitHub. Replaces
  # the old Set-ParamLine + Invoke-GitPush two-step, which raced under parallel runs.
  #   -Param  array of @{ Pattern='<regex>'; Replacement='<text>' } edits to main.parameters.json
  #   -Files  additional already-modified files to stage (e.g. src\quiz-service\server.js)
  #   -Message commit message
  param(
    [hashtable[]]$Param = @(),
    [string[]]$Files = @(),
    [Parameter(Mandatory)][string]$Message
  )
  # Don't let a non-zero git exit (e.g. "nothing to commit") throw; we check state explicitly.
  $PSNativeCommandUseErrorActionPreference = $false
  Invoke-WithRepoLock {
    Push-Location $script:RepoRoot
    try {
      $branch = (git rev-parse --abbrev-ref HEAD).Trim()
      $stage = [System.Collections.Generic.List[string]]::new()
      foreach ($f in $Files) { $stage.Add($f) }
      if ($Param.Count) {
        $content = Get-Content -Raw $script:ParamFile
        $changed = $false
        foreach ($ch in $Param) {
          if ($content -match [regex]::Escape($ch.Replacement)) { continue }
          $new = [regex]::Replace($content, $ch.Pattern, $ch.Replacement)
          if ($new -eq $content) { throw "Param pattern not found in $($script:ParamFile): $($ch.Pattern)" }
          $content = $new; $changed = $true
        }
        if ($changed) {
          Set-Content -Path $script:ParamFile -Value $content -NoNewline
          $stage.Add("infra\main.parameters.json")
        }
      }
      if ($stage.Count -eq 0) { Write-Host "  (already set in source — nothing to commit)" -ForegroundColor DarkGray; return }
      git add -- @($stage) | Out-Null
      if (-not (git diff --cached --name-only)) { Write-Host "  (no source change to commit)" -ForegroundColor DarkGray; return }
      # Commit first so the worktree is clean before we rebase onto any concurrent pushes.
      git commit -m $Message | Out-Null
      for ($i = 1; $i -le 4; $i++) {
        git pull --rebase --quiet origin $branch 2>$null | Out-Null
        git push --quiet origin $branch 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
          Write-Host "  Pushed source change to GitHub ${branch}: $Message" -ForegroundColor Cyan
          return
        }
        Start-Sleep -Milliseconds (300 * $i)
      }
      Write-Host "  (push retries exhausted; change committed locally on $branch)" -ForegroundColor DarkYellow
    } finally { Pop-Location }
  }
}

function Invoke-GitPush {
  # Back-compat shim — delegates to the concurrency-safe Set-IaCFault. Stages and pushes
  # already-modified files (no param edits).
  param(
    [Parameter(Mandatory)][string]$Message,
    [string[]]$Files = @("infra\main.parameters.json")
  )
  Set-IaCFault -Files $Files -Message $Message
}

function Get-PgServerName {
  param([Parameter(Mandatory)][string]$ResourceGroup)
  $server = az postgres flexible-server list -g $ResourceGroup --query "[0].name" -o tsv
  if (-not $server) { throw "Could not locate a PostgreSQL Flexible Server in $ResourceGroup." }
  return $server
}

function Get-PgAdminLogin {
  param([Parameter(Mandatory)][string]$ResourceGroup)
  $server = Get-PgServerName -ResourceGroup $ResourceGroup
  $login = az postgres flexible-server show -g $ResourceGroup -n $server --query administratorLogin -o tsv
  if (-not $login) { throw "Could not resolve administratorLogin for PostgreSQL server $server." }
  return $login
}

function Get-KeyVaultName {
  param([Parameter(Mandatory)][string]$ResourceGroup)
  $kv = az keyvault list -g $ResourceGroup --query "[0].name" -o tsv
  if (-not $kv) { throw "Could not locate a Key Vault in $ResourceGroup." }
  return $kv
}

function Get-KvSecret {
  param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$Name
  )
  $kv = Get-KeyVaultName -ResourceGroup $ResourceGroup
  $value = az keyvault secret show --vault-name $kv -n $Name --query value -o tsv
  if (-not $value) { throw "Could not read Key Vault secret '$Name' from $kv." }
  return $value
}

function Set-KvSecret {
  param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Value
  )
  $kv = Get-KeyVaultName -ResourceGroup $ResourceGroup
  az keyvault secret set --vault-name $kv -n $Name --value $Value -o none
}

function Get-AppGwName {
  param([Parameter(Mandatory)][string]$ResourceGroup)
  $token = Get-ResourceToken -ResourceGroup $ResourceGroup
  $name = "agw-zava-$token"
  $exists = az network application-gateway show -g $ResourceGroup -n $name --query name -o tsv 2>$null
  if (-not $exists) { throw "Could not locate Application Gateway $name in $ResourceGroup." }
  return $name
}

function Get-ReportingVmName {
  param([Parameter(Mandatory)][string]$ResourceGroup)
  $vm = az vm list -g $ResourceGroup --query "[?starts_with(name,'vm-zava-reporting-')].name | [0]" -o tsv
  if (-not $vm) { throw "Could not locate the reporting-worker VM (vm-zava-reporting-*) in $ResourceGroup." }
  return $vm
}

function Invoke-PgSql {
  param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$Database,
    [string]$Sql,
    [string]$FilePath
  )
  if ($Sql -and $FilePath) { throw "Invoke-PgSql accepts either -Sql or -FilePath, not both." }
  if (-not $Sql -and -not $FilePath) { throw "Invoke-PgSql requires -Sql or -FilePath." }

  $server = Get-PgServerName -ResourceGroup $ResourceGroup
  $fqdn   = az postgres flexible-server show -g $ResourceGroup -n $server --query fullyQualifiedDomainName -o tsv
  if (-not $fqdn) { throw "Could not resolve the FQDN for PostgreSQL server $server." }
  $login  = Get-PgAdminLogin -ResourceGroup $ResourceGroup
  $pw     = Get-KvSecret -ResourceGroup $ResourceGroup -Name "db-password"

  if ($FilePath) {
    $resolved = if ([System.IO.Path]::IsPathRooted($FilePath)) { $FilePath } else { Join-Path $script:RepoRoot $FilePath }
    if (-not (Test-Path $resolved)) { throw "SQL file not found: $resolved" }
    $sqlText = Get-Content -Raw $resolved
  } else {
    $sqlText = $Sql
  }

  # Execute via Python + psycopg2. The `rdbms-connect` az CLI extension (which backs
  # `az postgres flexible-server execute`) fails to install reliably on this host, so the old
  # path silently no-op'd the DB faults while still paging PagerDuty. psycopg2 connects over the
  # public endpoint with the admin credentials and runs the statement(s) with autocommit so DDL
  # (DROP INDEX / CREATE INDEX / ANALYZE / ALTER ROLE) actually takes effect. Throws on failure
  # so a break that did not land aborts before paging.
  $py = @'
import os, sys
try:
    import psycopg2
except ImportError:
    sys.stderr.write("psycopg2 is not installed in the active Python; cannot run DB chaos SQL.\n")
    sys.exit(2)
try:
    conn = psycopg2.connect(host=os.environ["PG_HOST"], user=os.environ["PG_USER"],
                            password=os.environ["PG_PASSWORD"], dbname=os.environ["PG_DB"],
                            sslmode="require", connect_timeout=15)
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute(os.environ["PG_SQL"])
    conn.close()
except Exception as e:
    sys.stderr.write("PgSql error: %s: %s\n" % (type(e).__name__, e))
    sys.exit(1)
'@
  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("zava-pgsql-{0}.py" -f ([guid]::NewGuid().ToString('N')))
  Set-Content -Path $tmp -Value $py -Encoding utf8
  try {
    $env:PG_HOST=$fqdn; $env:PG_USER=$login; $env:PG_PASSWORD=$pw; $env:PG_DB=$Database; $env:PG_SQL=$sqlText
    python $tmp
    $code = $LASTEXITCODE
  } finally {
    Remove-Item $tmp -ErrorAction SilentlyContinue
    Remove-Item Env:\PG_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:\PG_SQL -ErrorAction SilentlyContinue
  }
  if ($code -ne 0) { throw "Invoke-PgSql failed against database '$Database' on $server (exit $code; see error above)." }
}

function Build-And-DeployLane {
  param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$SrcFolder,
    [Parameter(Mandatory)][string]$AppName,
    [Parameter(Mandatory)][string]$Tag
  )
  $acr = az acr list -g $ResourceGroup --query "[0].name" -o tsv
  if (-not $acr) { throw "Could not locate the ACR in $ResourceGroup." }
  $src = Join-Path $script:RepoRoot "src\$SrcFolder"
  $image = "$acr.azurecr.io/${SrcFolder}:$Tag"
  Write-Host "    building $image (ACR cloud build)..." -ForegroundColor DarkGray
  az acr build -r $acr -t "${SrcFolder}:$Tag" $src -o none
  Write-Host "    rolling $AppName to the new image..." -ForegroundColor DarkGray
  az containerapp update -g $ResourceGroup -n $AppName --image $image -o none
  return $image
}

$script:QuizServer     = Join-Path $RepoRoot "src\quiz-service\server.js"
$script:QuizReleaseDir = Join-Path $RepoRoot "src\quiz-service\releases"
$script:QuizPerfClean  = Join-Path $QuizReleaseDir "server.v1.0.js"
$script:QuizPerfBad    = Join-Path $QuizReleaseDir "server.v1.1.js"
$script:QuizPerfMarker = "tamper-evident quiz integrity receipts"

function Swap-QuizPerf {
  if (-not (Test-Path $script:QuizServer)) { throw "Quiz service source not found: $script:QuizServer" }
  if (-not (Test-Path $script:QuizPerfBad)) { throw "Quiz perf release not found: $script:QuizPerfBad" }

  $content = Get-Content -Raw $script:QuizServer
  $isBad = $content -match [regex]::Escape($script:QuizPerfMarker)
  if (-not (Test-Path $script:QuizPerfClean)) {
    if ($isBad) { throw "Cannot create clean v1.0 snapshot because server.js already contains the v1.1 marker." }
    Copy-Item -Path $script:QuizServer -Destination $script:QuizPerfClean
    Write-Host "  Saved pristine quiz-service v1.0 snapshot." -ForegroundColor DarkGray
  }
  if ($isBad) { return $false }
  Copy-Item -Path $script:QuizPerfBad -Destination $script:QuizServer -Force
  return $true
}

function Restore-QuizPerf {
  if (-not (Test-Path $script:QuizServer)) { throw "Quiz service source not found: $script:QuizServer" }
  $content = Get-Content -Raw $script:QuizServer
  $isBad = $content -match [regex]::Escape($script:QuizPerfMarker)
  if (-not (Test-Path $script:QuizPerfClean)) {
    if ($isBad) { throw "Clean v1.0 snapshot missing: $script:QuizPerfClean" }
    return $false
  }
  $clean = Get-Content -Raw $script:QuizPerfClean
  if ($content -eq $clean) { return $false }
  Copy-Item -Path $script:QuizPerfClean -Destination $script:QuizServer -Force
  return $true
}

function Get-PortalUrl {
  param([Parameter(Mandatory)][string]$ResourceGroup)
  $agw = az network application-gateway list -g $ResourceGroup --query "[0].name" -o tsv
  if (-not $agw) { throw "No Application Gateway found in $ResourceGroup." }
  $pipId = az network application-gateway show -g $ResourceGroup -n $agw `
            --query "frontendIPConfigurations[0].publicIPAddress.id" -o tsv
  if (-not $pipId) { throw "App Gateway $agw has no public frontend IP." }
  $fqdn = az network public-ip show --ids $pipId --query "dnsSettings.fqdn" -o tsv
  if (-not $fqdn) { $fqdn = az network public-ip show --ids $pipId --query ipAddress -o tsv }
  if (-not $fqdn) { throw "Could not resolve the App Gateway public address." }
  return "http://$fqdn"
}

function Test-StudentJourney {
  param(
    [Parameter(Mandatory)][string]$Url,
    [int]$TimeoutSec = 8
  )
  try {
    $home = Invoke-WebRequest -UseBasicParsing -Uri ($Url.TrimEnd('/') + "/") -TimeoutSec $TimeoutSec
    if ($home.StatusCode -ge 400) { return @{ ok = $false; detail = "portal GET / -> HTTP $($home.StatusCode)" } }
    $courses = Invoke-RestMethod -Uri ($Url.TrimEnd('/') + "/api/courses") -TimeoutSec $TimeoutSec
    $courseId = $courses.courses[0].id
    if (-not $courseId) { return @{ ok = $false; detail = "no courses returned" } }
    $quiz = Invoke-RestMethod -Uri ($Url.TrimEnd('/') + "/api/quiz/$courseId") -TimeoutSec $TimeoutSec
    if (-not $quiz.questions) { return @{ ok = $false; detail = "quiz for $courseId returned no questions" } }
    return @{ ok = $true; detail = "portal + quiz $courseId OK ($($quiz.questions.Count) questions)" }
  } catch {
    $sc = $null
    try { $sc = $_.Exception.Response.StatusCode.value__ } catch {}
    $msg = if ($sc) { "HTTP $sc" } else { $_.Exception.Message }
    return @{ ok = $false; detail = "journey failed: $msg" }
  }
}

function New-PagerDutyIncident {
  param(
    [Parameter(Mandatory)][string]$Title,
    [Parameter(Mandatory)][string]$Details,
    [ValidateSet("high","low")][string]$Urgency = "high",
    [string]$Priority = ""
  )
  $token = Get-EnvFileValue -Key "PAGERDUTY_API_TOKEN"
  $svc   = Get-EnvFileValue -Key "PAGERDUTY_SERVICE_ID"
  if (-not $token -or -not $svc) {
    Write-Host "  (PagerDuty creds missing in sre-config\.env; cannot page)" -ForegroundColor DarkYellow
    return $null
  }
  $headers = @{
    "Authorization" = "Token token=$token"
    "Accept"        = "application/vnd.pagerduty+json;version=2"
    "Content-Type"  = "application/json"
  }
  $from = Get-EnvFileValue -Key "PAGERDUTY_FROM_EMAIL"
  if (-not $from) {
    try {
      $u = Invoke-RestMethod -Method GET -Uri "https://api.pagerduty.com/users?limit=1" -Headers $headers -TimeoutSec 15
      $from = $u.users[0].email
    } catch {}
  }
  if ($from) { $headers["From"] = $from }

  # Every incident gets a priority so on-call sees its severity (P2 by default; override with
  # PAGERDUTY_DEFAULT_PRIORITY in .env, or pass -Priority "none" to omit). Resolve the name -> id
  # against the account's priorities (requires the PagerDuty priorities feature to be enabled).
  if (-not $Priority) {
    $Priority = Get-EnvFileValue -Key "PAGERDUTY_DEFAULT_PRIORITY"
    if (-not $Priority) { $Priority = "P2" }
  }
  $priorityId = $null
  if ($Priority -and $Priority -ne "none") {
    try {
      $prios = Invoke-RestMethod -Method GET -Headers $headers -TimeoutSec 15 -Uri "https://api.pagerduty.com/priorities"
      $priorityId = ($prios.priorities | Where-Object { $_.name -eq $Priority } | Select-Object -First 1).id
      if (-not $priorityId) { Write-Host "  (PagerDuty priority '$Priority' not found; creating without priority)" -ForegroundColor DarkYellow }
    } catch { Write-Host "  (could not resolve PagerDuty priorities; creating without priority)" -ForegroundColor DarkYellow }
  }

  try {
    $open = Invoke-RestMethod -Method GET -Headers $headers -TimeoutSec 15 `
      -Uri ("https://api.pagerduty.com/incidents?statuses[]=triggered&statuses[]=acknowledged&service_ids[]=$svc&limit=50")
    $dup = $open.incidents | Where-Object { $_.title -eq $Title } | Select-Object -First 1
    if ($dup) {
      Write-Host "  PagerDuty incident already open ($($dup.id)) — not duplicating." -ForegroundColor DarkGray
      return $dup
    }
  } catch {}

  $incident = @{
    type    = "incident"
    title   = $Title
    service = @{ id = $svc; type = "service_reference" }
    urgency = $Urgency
    body    = @{ type = "incident_body"; details = $Details }
  }
  if ($priorityId) { $incident["priority"] = @{ id = $priorityId; type = "priority_reference" } }
  $body = @{ incident = $incident } | ConvertTo-Json -Depth 6
  try {
    $r = Invoke-RestMethod -Method POST -Uri "https://api.pagerduty.com/incidents" -Headers $headers -Body $body -TimeoutSec 20
    $prioNote = if ($priorityId) { " [$Priority]" } else { "" }
    Write-Host "  PagerDuty incident created: $($r.incident.id)$prioNote — $Title" -ForegroundColor Cyan
    return $r.incident
  } catch {
    Write-Host "  PagerDuty create failed: $($_.Exception.Message)" -ForegroundColor Red
    return $null
  }
}

function Resolve-OpenPagerDutyIncidents {
  $token = Get-EnvFileValue -Key "PAGERDUTY_API_TOKEN"
  $svc   = Get-EnvFileValue -Key "PAGERDUTY_SERVICE_ID"
  if (-not $token -or -not $svc) {
    Write-Host "  (PagerDuty creds missing in sre-config\.env; skipping incident cleanup)" -ForegroundColor DarkYellow
    return
  }
  $headers = @{
    "Authorization" = "Token token=$token"
    "Accept"        = "application/vnd.pagerduty+json;version=2"
    "Content-Type"  = "application/json"
  }
  $from = Get-EnvFileValue -Key "PAGERDUTY_FROM_EMAIL"
  if (-not $from) {
    try { $u = Invoke-RestMethod -Method GET -Uri "https://api.pagerduty.com/users?limit=1" -Headers $headers -TimeoutSec 15; $from = $u.users[0].email } catch {}
  }
  if (-not $from) { Write-Host "  (no PagerDuty From email resolvable; skipping incident cleanup)" -ForegroundColor DarkYellow; return }
  $headers["From"] = $from
  try {
    $open = Invoke-RestMethod -Method GET -Headers $headers -TimeoutSec 15 `
      -Uri "https://api.pagerduty.com/incidents?statuses[]=triggered&statuses[]=acknowledged&service_ids[]=$svc&limit=100"
  } catch {
    Write-Host "  PagerDuty list failed: $($_.Exception.Message)" -ForegroundColor Red
    return
  }
  if (-not $open.incidents -or $open.incidents.Count -eq 0) {
    Write-Host "  PagerDuty already clean (no open incidents)." -ForegroundColor DarkGray
    return
  }
  foreach ($inc in $open.incidents) {
    $body = @{ incident = @{ type = "incident_reference"; status = "resolved" } } | ConvertTo-Json -Depth 5
    try {
      Invoke-RestMethod -Method PUT -Uri "https://api.pagerduty.com/incidents/$($inc.id)" -Headers $headers -Body $body -TimeoutSec 20 | Out-Null
      Write-Host "  Resolved PagerDuty incident $($inc.id) — $($inc.title)" -ForegroundColor Cyan
    } catch {
      Write-Host "  Could not resolve $($inc.id): $($_.Exception.Message)" -ForegroundColor Red
    }
  }
}

function Invoke-SyntheticGate {
  param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$Url,
    [int]$Failures = 3,
    [int]$IntervalSec = 10,
    [int]$TimeoutSec = 8,
    [string]$IncidentTitle = "Zava learner portal unreachable — students cannot launch quizzes",
    [int]$MaxAttempts = 12
  )
  if (-not $Url) { $Url = Get-PortalUrl -ResourceGroup $ResourceGroup }
  Write-Host "[synthetic] Probing student journey at $Url (need $Failures consecutive failures to page)..." -ForegroundColor Yellow
  $consecutive = 0
  $lastDetail  = ""
  for ($i = 1; $i -le $MaxAttempts; $i++) {
    $res = Test-StudentJourney -Url $Url -TimeoutSec $TimeoutSec
    $lastDetail = $res.detail
    if ($res.ok) {
      $consecutive = 0
      Write-Host ("  probe {0}/{1}: OK  ({2})" -f $i, $MaxAttempts, $res.detail) -ForegroundColor Green
    } else {
      $consecutive++
      Write-Host ("  probe {0}/{1}: FAIL [{2}/{3}]  ({4})" -f $i, $MaxAttempts, $consecutive, $Failures, $res.detail) -ForegroundColor Red
      if ($consecutive -ge $Failures) {
        Write-Host "[synthetic] $Failures consecutive failures — paging PagerDuty (Azure Monitor is blind to this outage)." -ForegroundColor Magenta
        $details = "Synthetic external probe of the student journey at $Url failed $Failures times in a row. Last result: $($res.detail). Students cannot load the portal or launch quizzes. Raised by chaos synthetic monitor (independent of Azure Monitor)."
        return (New-PagerDutyIncident -Title $IncidentTitle -Details $details -Urgency "high")
      }
    }
    if ($i -lt $MaxAttempts) { Start-Sleep -Seconds $IntervalSec }
  }
  Write-Host "[synthetic] Journey did not fail $Failures times in a row within $MaxAttempts probes — not paging. Last: $lastDetail" -ForegroundColor DarkYellow
  return $null
}
