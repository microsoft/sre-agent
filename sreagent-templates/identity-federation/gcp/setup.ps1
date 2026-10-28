#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][Alias('ManagedIdentityResourceId')][ValidateNotNullOrEmpty()][string]$ResourceId,
    [Parameter(Mandatory)][Alias('allowed-permissions')][ValidateSet('read-only', 'read-write')][string]$AllowedPermissions,
    [Alias('skip-approval')][ValidateSet('true', 'false')][string]$SkipApproval = 'false',
    [ValidateSet('project', 'organization')][string]$AssignmentScope = 'project',
    [string]$OrganizationId = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$SetupRoot = $PSScriptRoot
$PoolId = 'sre-agent-pool'
$ProviderId = 'sre-agent-provider'
$RoleId = 'SREAgentRole'
$Audience = '59f0a04a-b322-4310-adc9-39ac41e9631e'
$UuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

function Invoke-SetupCommand {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $stdoutFile = [IO.Path]::GetTempFileName()
    $stderrFile = [IO.Path]::GetTempFileName()
    try {
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $Command @Arguments 1> $stdoutFile 2> $stderrFile
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousPreference
        }
        $stdout = [IO.File]::ReadAllText($stdoutFile).Trim()
        $stderr = [IO.File]::ReadAllText($stderrFile).Trim()
        if ($exitCode -ne 0) {
            throw "$Command $($Arguments -join ' ') failed (exit $exitCode): $stderr"
        }
        return $stdout
    }
    finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force
    }
}

function Invoke-SetupJson {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $text = Invoke-SetupCommand $Command $Arguments
    return ,(ConvertFrom-Json -InputObject $text -AsHashtable -NoEnumerate)
}

function Invoke-TerraformApply {
    param([bool]$SkipApproval = $false)

    $arguments = @('apply', '-no-color', '-input=true', '-auto-approve=false')
    if ($SkipApproval) {
        $arguments = @('apply', '-no-color', '-input=false', '-auto-approve=true')
    }
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & terraform @arguments 2>&1 | Out-Host
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) {
        throw 'Terraform apply was cancelled or failed. No destroy is run; inspect the output before rerunning setup.'
    }
}

function Get-ProviderCondition {
    param(
        [AllowNull()][System.Collections.IDictionary]$Provider,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ObjectId
    )

    $ObjectId = $ObjectId.ToLowerInvariant()
    $newCondition = "assertion.oid == '$ObjectId'"
    if ($null -eq $Provider) {
        return @{ Condition = $newCondition; Reset = $false }
    }
    if (-not $Provider.Contains('oidc')) {
        throw 'The existing fixed-name provider is not OIDC. It cannot be safely adopted by this setup.'
    }

    $oidc = $Provider.oidc
    $mapping = $Provider['attributeMapping']
    $expectedIssuer = "https://login.microsoftonline.com/$($TenantId.ToLowerInvariant())/v2.0"
    $mappingMatches = $null -ne $mapping -and $mapping.Count -eq 1 -and
        $mapping.Contains('google.subject') -and
        $mapping['google.subject'] -cmatch '^\s*assertion\s*\.\s*tid\s*\+\s*([''"])::\1\s*\+\s*assertion\s*\.\s*oid\s*$'
    $compatible = $oidc['issuerUri'] -ceq $expectedIssuer -and
        @($oidc['allowedAudiences']).Count -eq 1 -and
        @($oidc['allowedAudiences'])[0] -ceq $Audience -and $mappingMatches -and
        [string]::IsNullOrEmpty($oidc['jwksJson'])
    $existingCondition = [string]$Provider['attributeCondition']
    if (-not $compatible -or [string]::IsNullOrWhiteSpace($existingCondition)) {
        return @{ Condition = $newCondition; Reset = $true }
    }

    $existingCondition = $existingCondition.Trim()
    $prefix = ''
    $ids = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    $quotedIdPattern = "(?:'$UuidPattern'|`"$UuidPattern`")"
    $comparisonPattern = "assertion\.oid\s*==\s*$quotedIdPattern"
    $orPattern = '^(?<prefix>\([\s\S]+\)\r?\n\|\|\s*)?(?<comparisons>' + $comparisonPattern + '(?:\s*\|\|\s*' + $comparisonPattern + ')*)$'
    $listPattern = '^(?<prefix>\([\s\S]+\)\r?\n\|\|\s*)?assertion\.oid\s+in\s+\[(?<values>[^\]]*)\]$'
    if ($existingCondition -cmatch $orPattern) {
        $prefix = [string]$Matches['prefix']
        foreach ($match in [regex]::Matches($Matches['comparisons'], $UuidPattern)) {
            [void]$ids.Add($match.Value.ToLowerInvariant())
        }
    }
    elseif ($existingCondition -cmatch $listPattern) {
        $prefix = [string]$Matches['prefix']
        $values = $Matches['values']
        foreach ($value in ($values -split ',')) {
            if ($value.Trim() -cnotmatch "^$quotedIdPattern$") {
                $prefix = "($existingCondition`n)`n|| "
                $ids.Clear()
                break
            }
            [void]$ids.Add([regex]::Match($value, $UuidPattern).Value.ToLowerInvariant())
        }
    }
    else {
        # A newline closes trailing CEL comments before adding managed comparisons.
        $prefix = "($existingCondition`n)`n|| "
    }

    [void]$ids.Add($ObjectId)
    $comparisons = @($ids | ForEach-Object { "assertion.oid == '$_'" }) -join ' || '
    $condition = "$prefix$comparisons"
    if ($condition.Length -gt 4096) {
        throw 'The merged provider condition exceeds the GCP 4096-character limit. Review the existing trust rules.'
    }
    return @{ Condition = $condition; Reset = $false }
}

function Assert-ActiveResource {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Resource,
        [Parameter(Mandatory)][string]$Name
    )

    if ($Resource['state'] -eq 'DELETED' -or $Resource['deleted'] -eq $true) {
        throw "$Name is soft-deleted. Restore it through your approved process before rerunning; its name cannot be reused yet."
    }
    if ($Resource['disabled'] -eq $true -or $Resource['stage'] -eq 'DISABLED') {
        throw "$Name is disabled. Review and enable it through your approved process before rerunning."
    }
}

function New-ImportBlock {
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][string]$Id
    )

    $quotedId = ConvertTo-Json -InputObject $Id -Compress
    return "import {`n  to = $Address`n  id = $quotedId`n}`n"
}

function Invoke-GcpSetup {
    param(
        [Parameter(Mandatory)][Alias('ManagedIdentityResourceId')][ValidateNotNullOrEmpty()][string]$ResourceId,
        [Parameter(Mandatory)][Alias('allowed-permissions')][ValidateSet('read-only', 'read-write')][string]$AllowedPermissions,
        [Alias('skip-approval')][ValidateSet('true', 'false')][string]$SkipApproval = 'false',
        [ValidateSet('project', 'organization')][string]$AssignmentScope = 'project',
        [string]$OrganizationId = ''
    )

    $identityResourceId = $ResourceId.Trim()
    if ($identityResourceId -notmatch "^/subscriptions/$UuidPattern/resourceGroups/[^/]+/providers/Microsoft\.ManagedIdentity/userAssignedIdentities/[^/]+$") {
        throw '-ResourceId must be a full Azure user-assigned managed identity resource ID.'
    }
    $accessMode = $AllowedPermissions.ToLowerInvariant()
    $scope = $AssignmentScope.ToLowerInvariant()
    $organizationId = $OrganizationId.Trim()
    if ($scope -eq 'organization' -and $organizationId -notmatch '^[0-9]+$') {
        throw '-OrganizationId is required for organization scope and must be numeric.'
    }
    if ($scope -eq 'project' -and $organizationId -ne '') {
        throw '-OrganizationId can only be supplied with -AssignmentScope organization.'
    }

    foreach ($command in @('az', 'gcloud', 'terraform')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Required command '$command' was not found. See README.md for prerequisites."
        }
    }
    $version = Invoke-SetupJson terraform @('version', '-json')
    if ($version.terraform_version.Contains('-') -or
        [version](($version.terraform_version -split '\+', 2)[0]) -lt [version]'1.7.0') {
        throw 'A stable Terraform 1.7 or later release is required.'
    }

    $accounts = Invoke-SetupJson gcloud @('auth', 'list', '--filter=status:ACTIVE', '--format=json')
    if (@($accounts).Count -ne 1) {
        throw 'No unique active gcloud account. Run gcloud auth login before setup.'
    }
    $configuredProject = Invoke-SetupCommand gcloud @('config', 'get', 'project')
    if ([string]::IsNullOrWhiteSpace($configuredProject) -or $configuredProject -eq '(unset)') {
        throw 'No GCP project configured. Run gcloud config set project <PROJECT_ID> before setup.'
    }
    $project = Invoke-SetupJson gcloud @('projects', 'describe', $configuredProject, '--format=json', '--quiet')
    $projectId = [string]$project.projectId
    $projectNumber = [string]$project.projectNumber
    if ($projectId -notmatch '^[a-z][a-z0-9-]{4,28}[a-z0-9]$' -or $projectNumber -notmatch '^[0-9]+$') {
        throw 'gcloud returned an invalid project ID or project number.'
    }
    $projectFlag = "--project=$projectId"
    $services = Invoke-SetupJson gcloud @('services', 'list', '--enabled', $projectFlag, '--format=json', '--quiet')
    $enabledServices = @($services | ForEach-Object { $_.config.name })
    foreach ($required in @('serviceusage.googleapis.com', 'iam.googleapis.com')) {
        if ($enabledServices -cnotcontains $required) {
            throw "Enable $required in $projectId through your approved process before setup. See README.md."
        }
    }

    Write-Host "`nSRE Agent GCP connector setup" -ForegroundColor Cyan
    Write-Host "Account: $($accounts[0].account)"
    Write-Host "Project: $projectId ($projectNumber)"
    $identity = Invoke-SetupJson az @(
        'identity', 'show', '--ids', $identityResourceId,
        '--query', '{tenantId:tenantId,principalId:principalId}', '--output', 'json'
    )
    if ([string]$identity.tenantId -notmatch "^$UuidPattern$" -or
        [string]$identity.principalId -notmatch "^$UuidPattern$") {
        throw 'Azure did not return a valid tenant ID and principal/object ID for the managed identity.'
    }
    $tenantId = $identity.tenantId.ToLowerInvariant()
    $objectId = $identity.principalId.ToLowerInvariant()
    $scopeFlag = $projectFlag
    $scopeParent = "projects/$projectId"
    if ($scope -eq 'organization') {
        $scopeFlag = "--organization=$organizationId"
        $scopeParent = "organizations/$organizationId"
        Write-Warning 'Organization-level access is inherited by descendant resources.'
    }

    $imports = [Collections.Generic.List[string]]::new()
    $poolName = "projects/$projectNumber/locations/global/workloadIdentityPools/$PoolId"
    $providerName = "$poolName/providers/$ProviderId"
    # Import stores this project segment in the replacement-only project field.
    $poolImportId = "projects/$projectId/locations/global/workloadIdentityPools/$PoolId"
    $roleName = "$scopeParent/roles/$RoleId"
    $principal = "principal://iam.googleapis.com/$poolName/subject/${tenantId}::$objectId"
    $pools = Invoke-SetupJson gcloud @(
        'iam', 'workload-identity-pools', 'list', '--location=global',
        '--show-deleted', $projectFlag, '--format=json', '--quiet'
    )
    $pool = @($pools | Where-Object { $_.name -ceq $poolName })
    $provider = $null
    if ($pool.Count -gt 0) {
        Assert-ActiveResource $pool[0] 'SREAgentPool'
        $imports.Add((New-ImportBlock 'google_iam_workload_identity_pool.sre_agent' $poolImportId))
        $providers = Invoke-SetupJson gcloud @(
            'iam', 'workload-identity-pools', 'providers', 'list', '--location=global',
            "--workload-identity-pool=$PoolId", '--show-deleted', $projectFlag, '--format=json', '--quiet'
        )
        $matchingProviders = @($providers | Where-Object { $_.name -ceq $providerName })
        if ($matchingProviders.Count -gt 0) {
            Assert-ActiveResource $matchingProviders[0] 'SREAgentProvider'
            $provider = Invoke-SetupJson gcloud @(
                'iam', 'workload-identity-pools', 'providers', 'describe', $ProviderId,
                '--location=global', "--workload-identity-pool=$PoolId", $projectFlag, '--format=json', '--quiet'
            )
            Assert-ActiveResource $provider 'SREAgentProvider'
            $imports.Add((New-ImportBlock 'google_iam_workload_identity_pool_provider.azure' "$poolImportId/providers/$ProviderId"))
        }
    }
    $trust = Get-ProviderCondition -Provider $provider -TenantId $tenantId -ObjectId $objectId
    if ($trust.Reset) {
        Write-Warning 'The existing provider configuration is incompatible or unrestricted. Terraform will correct its issuer/audience/mapping and replace its condition with ONLY the selected identity. Existing identities, including those in a different tenant, may lose access. Review the plan carefully.'
    }

    $roles = Invoke-SetupJson gcloud @('iam', 'roles', 'list', $scopeFlag, '--show-deleted', '--format=json', '--quiet')
    $role = @($roles | Where-Object { $_.name -ceq $roleName })
    $existingPermissions = @()
    if ($role.Count -gt 0) {
        Assert-ActiveResource $role[0] $RoleId
        $details = Invoke-SetupJson gcloud @('iam', 'roles', 'describe', $RoleId, $scopeFlag, '--format=json', '--quiet')
        Assert-ActiveResource $details $RoleId
        if (-not $details.Contains('includedPermissions')) {
            throw 'The existing custom role response has no includedPermissions; refusing to replace unknown permissions.'
        }
        $existingPermissions = @($details.includedPermissions)
        $imports.Add((New-ImportBlock "google_${scope}_iam_custom_role.sre_agent_role[0]" $roleName))
    }

    $policy = Invoke-SetupJson gcloud @(
        $(if ($scope -eq 'project') { 'projects' } else { 'organizations' }),
        'get-iam-policy', $(if ($scope -eq 'project') { $projectId } else { $organizationId }),
        '--format=json', '--quiet'
    )
    foreach ($binding in @($policy['bindings'])) {
        if ($null -ne $binding -and $binding.role -ceq $roleName -and
            -not $binding.Contains('condition') -and @($binding.members) -ccontains $principal) {
            $scopeId = if ($scope -eq 'project') { $projectId } else { $organizationId }
            $imports.Add((New-ImportBlock "google_${scope}_iam_member.sre_agent_role_assignment[0]" "$scopeId $roleName $principal"))
            break
        }
    }
    foreach ($service in @('iam.googleapis.com', 'cloudresourcemanager.googleapis.com', 'iamcredentials.googleapis.com', 'sts.googleapis.com')) {
        if ($enabledServices -ccontains $service) {
            $imports.Add((New-ImportBlock "google_project_service.required[`"$service`"]" "$projectId/$service"))
        }
    }

    $variables = [ordered]@{
        project_id                = $projectId
        project_number            = $projectNumber
        azure_tenant_id           = $tenantId
        uami_object_id            = $objectId
        access_mode               = $accessMode
        assignment_scope          = $scope
        organization_id           = $organizationId
        attribute_condition       = $trust.Condition
        existing_role_permissions = $existingPermissions
    }
    Write-Host "Azure tenant: $tenantId"
    Write-Host "Managed identity object ID: $objectId"
    Write-Host "Provider: $providerName"
    Write-Host "Role: $roleName"
    Write-Host "Permissions to add: $accessMode; preserve $($existingPermissions.Count) existing permissions."
    Write-Warning 'All SREAgentRole assignees share the merged permissions. Read-only does not downgrade an existing read-write role.'
    Write-Warning 'Run setups sequentially. Do not adopt resources concurrently managed by another Terraform state. The temporary named workspace will be deleted WITHOUT destroying GCP resources.'

    $workspace = "sre-agent-gcp-$([Guid]::NewGuid().ToString('N'))"
    $runDirectory = Join-Path ([IO.Path]::GetTempPath()) $workspace
    $environmentNames = @('TF_WORKSPACE', 'TF_DATA_DIR', 'GOOGLE_OAUTH_ACCESS_TOKEN', 'GOOGLE_CREDENTIALS', 'GOOGLE_CLOUD_KEYFILE_JSON', 'GCLOUD_KEYFILE_JSON', 'GOOGLE_IMPERSONATE_SERVICE_ACCOUNT')
    $previousEnvironment = @{}
    foreach ($name in $environmentNames) {
        $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    $workspaceCreated = $false
    $directoryCreated = $false
    $locationPushed = $false
    $cleanupError = $null
    try {
        [void](New-Item -ItemType Directory -Path $runDirectory)
        $directoryCreated = $true
        Copy-Item -Path (Join-Path $SetupRoot '*.tf') -Destination $runDirectory
        [IO.File]::WriteAllText((Join-Path $runDirectory 'guided.auto.tfvars.json'), ($variables | ConvertTo-Json -Depth 20))
        [IO.File]::WriteAllText((Join-Path $runDirectory 'imports.tf'), ($imports -join "`n"))
        foreach ($name in $environmentNames) {
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }
        # Use the same gcloud principal for discovery and Terraform, not an
        # unrelated application-default credential. Never persist this token.
        $token = Invoke-SetupCommand gcloud @('auth', 'print-access-token', '--quiet')
        if ([string]::IsNullOrWhiteSpace($token)) {
            throw 'gcloud returned an empty access token. Run gcloud auth login again.'
        }
        [Environment]::SetEnvironmentVariable('GOOGLE_OAUTH_ACCESS_TOKEN', $token, 'Process')
        Push-Location $runDirectory
        $locationPushed = $true
        Write-Host (Invoke-SetupCommand terraform @('init', '-input=false', '-no-color'))
        Write-Host (Invoke-SetupCommand terraform @('workspace', 'new', $workspace))
        $workspaceCreated = $true
        if ([bool]::Parse($SkipApproval)) {
            Write-Warning 'Approval is explicitly skipped. Terraform will apply all proposed changes without confirmation, including any provider trust reset or shared-role permission expansion.'
        }
        Invoke-TerraformApply -SkipApproval ([bool]::Parse($SkipApproval))
        $outputs = Invoke-SetupJson terraform @('output', '-json')
        Write-Host "`nCopy this Workload Identity Provider into the SRE Agent GCP connector:" -ForegroundColor Green
        Write-Host $outputs.workload_identity_provider.value
        Write-Host "Role: $($outputs.role_name.value)"
        Write-Host "Principal: $($outputs.principal_id.value)"
    }
    finally {
        try {
            if ($workspaceCreated) {
                Write-Host (Invoke-SetupCommand terraform @('workspace', 'select', 'default'))
                Write-Host (Invoke-SetupCommand terraform @('workspace', 'delete', '-force', $workspace))
            }
        }
        catch {
            $cleanupError = $_
            Write-Warning "Workspace cleanup failed. Local state is retained at $runDirectory. $($_.Exception.Message)"
        }
        finally {
            if ($locationPushed) {
                Pop-Location
            }
            foreach ($name in $environmentNames) {
                [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
            }
        }
        if ($null -eq $cleanupError -and $directoryCreated -and (Test-Path -LiteralPath $runDirectory)) {
            Remove-Item -LiteralPath $runDirectory -Recurse -Force
        }
        if ($null -ne $cleanupError) {
            throw $cleanupError
        }
    }
    Write-Host 'GCP setup completed; the temporary Terraform workspace and local files were removed.'
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-GcpSetup @PSBoundParameters
}
