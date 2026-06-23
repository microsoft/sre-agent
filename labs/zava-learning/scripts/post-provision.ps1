<#
.SYNOPSIS
  Post-provision step for the Zava Learning lab. Builds and pushes service images to
  ACR, points the container apps at them, seeds PostgreSQL, and writes simulator config.

  Run after the infra deployment (main.bicep) completes.
#>
param(
  [string]$ResourceGroup = "rg-zava-learning-demo"
)
$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot "chaos\_common.ps1")

Write-Host "== Post-provision: $ResourceGroup ==" -ForegroundColor Cyan

$acr = az acr list -g $ResourceGroup --query "[0].name" -o tsv
if (-not $acr) { throw "No ACR found in $ResourceGroup." }
$subscription = az account show --query id -o tsv
$token = Get-ResourceToken -ResourceGroup $ResourceGroup
$baseTag = "v1.0-$token"

$services = @(
  @{ name = "learner-portal"; path = "src\learner-portal"; tag = "latest" },
  @{ name = "course-api";     path = "src\course-api";     tag = "latest" },
  @{ name = "assessment-api"; path = "src\assessment-api"; tag = "latest" },
  @{ name = "gradebook-api";  path = "src\gradebook-api";  tag = "latest" }
)

foreach ($svc in $services) {
  $img = "$($svc.name):$($svc.tag)"
  Write-Host "Building $img from $($svc.path)..." -ForegroundColor Yellow
  az acr build --registry $acr --image $img (Join-Path $repoRoot $svc.path) -o none
}

$quizImg = "quiz-service:$baseTag"
Write-Host "Building $quizImg from src\quiz-service..." -ForegroundColor Yellow
az acr build --registry $acr --image $quizImg (Join-Path $repoRoot "src\quiz-service") -o none

foreach ($svc in $services) {
  $img = "$($acr).azurecr.io/$($svc.name):$($svc.tag)"
  Write-Host "Updating container app $($svc.name) -> $img" -ForegroundColor Yellow
  az containerapp update --resource-group $ResourceGroup --name $svc.name --image $img -o none
}

$quizImageRef = "$acr.azurecr.io/quiz-service:$baseTag"
$laneApps = @("quiz-appgw", "quiz-app", "quiz-perf", "quiz-query", "quiz-pool", "quiz-secret", "quiz-nsg")
foreach ($app in $laneApps) {
  Write-Host "Updating container app $app -> $quizImageRef" -ForegroundColor Yellow
  az containerapp update --resource-group $ResourceGroup --name $app --image $quizImageRef -o none
}

Write-Host "Opening PostgreSQL firewall for the deployer IP..." -ForegroundColor Yellow
$server = Get-PgServerName -ResourceGroup $ResourceGroup
$deployerIp = (Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 15).Trim()
az postgres flexible-server firewall-rule create --resource-group $ResourceGroup --name $server `
  --rule-name "AllowDeployerPostProvision" --start-ip-address $deployerIp --end-ip-address $deployerIp -o none

$schemaPath = Join-Path $repoRoot "src\db\schema.sql"
Write-Host "Seeding database zava from src\db\schema.sql..." -ForegroundColor Yellow
Invoke-PgSql -ResourceGroup $ResourceGroup -Database "zava" -FilePath $schemaPath
Write-Host "Seeding database zava_query from src\db\schema.sql..." -ForegroundColor Yellow
Invoke-PgSql -ResourceGroup $ResourceGroup -Database "zava_query" -FilePath $schemaPath

Write-Host "Creating/updating app_pool role grants..." -ForegroundColor Yellow
$poolPw = Get-KvSecret -ResourceGroup $ResourceGroup -Name "db-pool-password"
$poolPwSql = $poolPw.Replace("'", "''")
$poolSqlTemplate = @(
  'DO $$',
  'BEGIN',
  "  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='app_pool') THEN",
  "    CREATE ROLE app_pool LOGIN PASSWORD '__POOL_PASSWORD__';",
  '  END IF;',
  'END $$;',
  'GRANT CONNECT ON DATABASE zava TO app_pool;',
  'GRANT USAGE ON SCHEMA public TO app_pool;',
  'GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA public TO app_pool;',
  'GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_pool;'
) -join "`n"
$poolSql = $poolSqlTemplate.Replace("__POOL_PASSWORD__", $poolPwSql)
Invoke-PgSql -ResourceGroup $ResourceGroup -Database "zava" -Sql $poolSql

# Resolve the public entry point (App Gateway public IP FQDN).
$pip = az network public-ip list -g $ResourceGroup --query "[?starts_with(name,'pip-agw')].dnsSettings.fqdn | [0]" -o tsv
$appgwUrl = if ($pip) { "http://$pip" } else { "" }

$config = [ordered]@{
  appgw_url      = $appgwUrl
  resource_group = $ResourceGroup
  subscription   = $subscription
  agent_name     = ""
  pagerduty      = [ordered]@{ api_token = ""; service_id = "" }
}
$configPath = Join-Path $repoRoot "simulator\config.json"
$config | ConvertTo-Json -Depth 5 | Set-Content -Path $configPath -Encoding UTF8

Write-Host ""
Write-Host "Done. Public endpoint: $appgwUrl" -ForegroundColor Green
Write-Host "Simulator config written to $configPath" -ForegroundColor Green
Write-Host "Set agent_name + pagerduty.api_token in that file (or env vars) to enable agent/PD polling." -ForegroundColor DarkGray
