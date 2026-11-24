# Checks and installs everything the Caldova Retail Ops lab needs and signs you in.
# Safe to run more than once.
# Usage: irm https://raw.githubusercontent.com/microsoft/sre-agent/main/labs/caldova-retail-ops/setup.ps1 | iex
$ErrorActionPreference = 'Continue'

function Ok($m)    { Write-Host "  [OK] $m" -ForegroundColor Green }
function Doing($m) { Write-Host "  ->   $m" -ForegroundColor Yellow }
function Step($n, $m) { Write-Host "`n[$n] $m" -ForegroundColor White }
function Fail($m, $hint) {
    Write-Host "`nX $m" -ForegroundColor Red
    if ($hint) { Write-Host "  $hint" }
    throw 'Setup stopped.'
}
function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}
function Test-Cmd($cmd) {
    try { & $cmd[0] $cmd[1..($cmd.Length - 1)] *> $null; return $LASTEXITCODE -eq 0 } catch { return $false }
}

Step '1/5' 'Package manager'
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Fail 'winget is not available.' 'Install "App Installer" from the Microsoft Store, then run the setup command again.'
}
Ok 'winget'

Step '2/5' 'Tools'
$tools = @(
    @{ Name = 'Git';                 Check = @('git', '--version');  Id = 'Git.Git' },
    @{ Name = 'Azure CLI';           Check = @('az', 'version');     Id = 'Microsoft.AzureCLI' },
    @{ Name = 'Azure Developer CLI'; Check = @('azd', 'version');    Id = 'Microsoft.Azd' },
    @{ Name = 'GitHub CLI';          Check = @('gh', '--version');   Id = 'GitHub.cli' }
)
foreach ($t in $tools) {
    if (Test-Cmd $t.Check) { Ok $t.Name; continue }
    Doing "Installing $($t.Name)"
    winget install -e --id $t.Id --accept-source-agreements --accept-package-agreements --silent | Out-Null
    Refresh-Path
    if (-not (Test-Cmd $t.Check)) { Fail "$($t.Name) is still not available." 'Close and reopen PowerShell, then run the setup command again.' }
    Ok $t.Name
}
function Has-Dotnet8 {
    try { $sdks = dotnet --list-sdks 2>$null } catch { return $false }
    return [bool]($sdks | Where-Object { [int]($_.Split('.')[0]) -ge 8 })
}
if (Has-Dotnet8) {
    Ok ".NET SDK $(dotnet --version)"
} else {
    Doing 'Installing .NET SDK 8'
    winget install -e --id Microsoft.DotNet.SDK.8 --accept-source-agreements --accept-package-agreements --silent | Out-Null
    Refresh-Path
    if (-not (Has-Dotnet8)) { Fail '.NET SDK 8 or later is still not available.' 'Close and reopen PowerShell, then run the setup command again.' }
    Ok ".NET SDK $(dotnet --version)"
}

Step '3/5' 'Git identity and GitHub sign-in'
if (-not (git config --global user.name) -or -not (git config --global user.email)) {
    Write-Host '  Git needs a name and email to label your commits (asked once, saved on this machine).'
}
while (-not (git config --global user.name)) {
    $gname = Read-Host '  Your full name, e.g. Jane Doe'
    if ($gname) { git config --global user.name $gname }
}
while (-not (git config --global user.email)) {
    $gmail = Read-Host '  Your email, ideally the one on your GitHub account'
    if ($gmail) { git config --global user.email $gmail }
}
Ok "Git identity: $(git config --global user.name) <$(git config --global user.email)>"
gh auth status -h github.com *> $null
if ($LASTEXITCODE -ne 0) {
    Doing 'Signing in to GitHub (opens your browser)'
    gh auth login -h github.com -p https --git-protocol https --web
    if ($LASTEXITCODE -ne 0) { Fail 'GitHub sign-in failed.' }
}
Ok "GitHub: $(gh api user --jq .login 2>$null)"

Step '4/5' 'Azure sign-in'
az account get-access-token --output none *> $null
if ($LASTEXITCODE -ne 0) {
    Doing 'Signing in to Azure CLI (opens your browser)'
    az login --output none
    if ($LASTEXITCODE -ne 0) { Fail 'Azure CLI sign-in failed.' }
}
Ok 'Azure CLI signed in'
azd auth token --output json *> $null
if ($LASTEXITCODE -ne 0) {
    Doing 'Signing in to Azure Developer CLI (opens your browser)'
    azd auth login
    azd auth token --output json *> $null
    if ($LASTEXITCODE -ne 0) { Fail 'azd sign-in did not produce a valid token.' }
}
Ok 'Azure Developer CLI signed in'

Step '5/5' 'Subscription'
$current = az account show --query "join('', [name, ' (', id, ')'])" -o tsv
$yn = Read-Host "  Use subscription $current? [Y/n]"
if ($yn -match '^[Nn]') {
    $pick = Read-Host '  Subscription name or ID'
    az account set --subscription $pick
    if ($LASTEXITCODE -ne 0) { Fail "Could not select subscription '$pick'." 'List yours with: az account list -o table' }
}
$subId = az account show --query id -o tsv
Ok "Subscription: $(az account show --query name -o tsv) ($subId)"

$permUrl = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.Authorization/permissions?api-version=2022-04-01"
$canCreate = [int](az rest --method get --url $permUrl --query "length(value[?contains(actions, '*')])" -o tsv 2>$null)
$canRbac = [int](az rest --method get --url $permUrl --query "length(value[?(contains(actions, '*') && length(notActions) == ``0``) || contains(actions, 'Microsoft.Authorization/*')])" -o tsv 2>$null)
if ($canCreate -gt 0 -and $canRbac -gt 0) {
    Ok 'Permissions: can create resources and role assignments'
} else {
    Fail "Your account can't create both resources and role assignments in this subscription." 'You need Owner, or Contributor + User Access Administrator. Ask a subscription owner, or pick another subscription.'
}

$state = az provider show -n Microsoft.App --query registrationState -o tsv 2>$null
if ($state -ne 'Registered') {
    Doing 'Registering the Microsoft.App resource provider (1-2 minutes)'
    az provider register --namespace Microsoft.App --wait
    if ($LASTEXITCODE -ne 0) { Fail 'Provider registration failed.' }
}
Ok 'Microsoft.App resource provider registered'

Write-Host "`nAll prerequisites are ready. Continue with step 2 in the lab README.`n" -ForegroundColor Green
