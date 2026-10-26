[CmdletBinding()]
param(
    [string]$ResourceId,
    [Alias('allowed-permissions')]
    [string]$AllowedPermissions,
    [Alias('skip-approval')]
    [ValidateSet('true', 'false')]
    [string]$SkipApproval = 'false'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RoleName = 'SREAgentRole'
$GeneratedVariablesFile = Join-Path $PSScriptRoot 'guided.auto.tfvars.json'
$PlanFile = Join-Path $PSScriptRoot 'tfplan'
$AgentApiVersion = '2025-05-01-preview'
$PolicyDescriptions = [ordered]@{
    SREAgentReadOnlyAccess = 'Inspect AWS resources and telemetry, read application data and secrets, and decrypt data.'
    SREAgentWriteAccess = 'Open workload sessions and database connections; restart, stop, scale, or recover resources.'
}

Write-Host ''
Write-Host 'SRE Agent AWS connector setup' -ForegroundColor Cyan
Write-Host 'This script reads the Azure managed identity and lets Terraform configure AWS.'

if (-not $PSBoundParameters.ContainsKey('ResourceId')) {
    $ResourceId = Read-Host 'Enter the full ARM resource ID of the user-assigned managed identity or SRE Agent'
}
$identityResourceId = $ResourceId.Trim()
$subscriptionPattern = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
$resourceIdPattern = "(?i)^/subscriptions/$subscriptionPattern/resourceGroups/[^/\s?#]+/providers/(?<resourceType>Microsoft\.ManagedIdentity/userAssignedIdentities|Microsoft\.App/agents)/[^/\s?#]+$"
if ($identityResourceId -notmatch $resourceIdPattern) {
    throw 'Invalid ARM resource ID. Expected /subscriptions/<subscription-guid>/resourceGroups/<group>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<name> or Microsoft.App/agents/<name>.'
}
$identityType = if ($Matches.resourceType -ieq 'Microsoft.ManagedIdentity/userAssignedIdentities') { 'UserAssigned' } else { 'SystemAssigned' }

if (-not $PSBoundParameters.ContainsKey('AllowedPermissions')) {
    Write-Host ''
    Write-Host 'Available permission levels:' -ForegroundColor Cyan
    Write-Host "  read-only - SREAgentReadOnlyAccess: $($PolicyDescriptions.SREAgentReadOnlyAccess)"
    Write-Host "  read-write - SREAgentReadOnlyAccess + SREAgentWriteAccess: $($PolicyDescriptions.SREAgentWriteAccess)"
    Write-Host 'Example: -allowed-permissions read-only (or read-write)'
    $AllowedPermissions = Read-Host 'Enter allowed permissions: read-only or read-write'
}
$AllowedPermissions = $AllowedPermissions.Trim().ToLowerInvariant()
if ($AllowedPermissions -cnotin @('read-only', 'read-write')) {
    throw 'Invalid allowed-permissions value. Choose read-only or read-write.'
}

$policyNames = @('SREAgentReadOnlyAccess')
if ($AllowedPermissions -eq 'read-write') {
    $policyNames += 'SREAgentWriteAccess'
}
$workloadPolicies = [ordered]@{}
$policySize = 0
$statementSids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($name in $policyNames) {
    $policyPath = Join-Path $PSScriptRoot "$name.json"
    if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) {
        throw "Policy JSON file not found: $policyPath"
    }
    try {
        $document = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "Policy '$policyPath' is not valid JSON: $($_.Exception.Message)"
    }
    if ($null -eq $document -or
        $null -eq $document.PSObject.Properties['Version'] -or
        $document.Version -ne '2012-10-17' -or
        $null -eq $document.PSObject.Properties['Statement'] -or
        $null -eq $document.Statement -or
        @($document.Statement).Count -eq 0) {
        throw "Policy '$policyPath' must contain Version 2012-10-17 and nonempty Statement objects."
    }
    foreach ($statement in @($document.Statement)) {
        if ($statement -isnot [PSCustomObject] -or
            $null -eq $statement.PSObject.Properties['Effect'] -or
            $statement.Effect -cnotin @('Allow', 'Deny')) {
            throw "Policy '$policyPath' contains an invalid Statement object."
        }
        $sidProperty = $statement.PSObject.Properties['Sid']
        if ($null -ne $sidProperty -and -not $statementSids.Add([string]$sidProperty.Value)) {
            throw "Duplicate policy statement Sid: $($sidProperty.Value)"
        }
    }
    $workloadPolicies[$name] = $document
    $policySize += ($document | ConvertTo-Json -Depth 100 -Compress).Length
}
if ($policySize -gt 10240) {
    throw 'The workload policies exceed the 10,240-character aggregate role inline-policy limit.'
}
$policySource = $policyNames -join ', '
Write-Host ''
Write-Host "Allowed permissions: $AllowedPermissions"
Write-Host 'Selected policies to apply:' -ForegroundColor Cyan
foreach ($name in $policyNames) {
    Write-Host "  $name - $($PolicyDescriptions[$name])"
}
Write-Warning 'Selected permissions are shared by every identity trusted by SREAgentRole. ReadOnlyAccess exposes data and credentials; WriteAccess permits workload changes and can cause outages.'

function Require-Command {
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found. Install it and try again."
    }
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $stdoutFile = [IO.Path]::GetTempFileName()
    $stderrFile = [IO.Path]::GetTempFileName()
    try {
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $Command @Arguments 1> $stdoutFile 2> $stderrFile
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        $stdoutText = [IO.File]::ReadAllText($stdoutFile).TrimEnd()
        $stderrText = [IO.File]::ReadAllText($stderrFile).TrimEnd()
        $diagnosticText = (@($stdoutText, $stderrText) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine

        return [PSCustomObject]@{
            ExitCode   = $exitCode
            StdOutText = $stdoutText
            StdErrText = $stderrText
            Text       = $diagnosticText
        }
    }
    finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-JsonCommand {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $result = Invoke-NativeCommand -Command $Command -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        throw "'$Command $($Arguments -join ' ')' failed: $($result.Text)"
    }

    return $result.StdOutText | ConvertFrom-Json
}

function Invoke-NativeStreamingCommand {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $Command @Arguments 2>&1 | Out-Host
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Test-AwsNoSuchEntity {
    param([Parameter(Mandatory)]$Result)

    return $Result.StdErrText -match '\(NoSuchEntity\)'
}

function Test-TerraformStateAddress {
    param([Parameter(Mandatory)][string]$Address)

    $result = Invoke-NativeCommand -Command terraform -Arguments @('state', 'list')
    if ($result.ExitCode -eq 0) {
        return @($result.StdOutText -split '\r?\n') -contains $Address
    }
    if ($result.Text -match 'No state file was found') {
        return $false
    }
    throw "Unable to read Terraform state: $($result.Text)"
}

function Assert-TerraformStateBinding {
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][string]$ExpectedArn
    )

    $result = Invoke-NativeCommand -Command terraform -Arguments @(
        'state', 'show', '-no-color', $Address
    )
    if ($result.ExitCode -ne 0) {
        throw "Unable to inspect the Terraform state binding for $Address`: $($result.Text)"
    }
    if ($result.StdOutText -notmatch '(?m)^\s*arn\s+=\s+"([^"]+)"') {
        throw "Terraform state for $Address does not contain an ARN."
    }
    if ($Matches[1] -ne $ExpectedArn) {
        throw "Terraform state address $Address is bound to $($Matches[1]), not $ExpectedArn. Use the authoritative state for the selected AWS account and resource."
    }
}

function Assert-CompatibleTools {
    $terraformResult = Invoke-NativeCommand -Command terraform -Arguments @('version', '-json')
    if ($terraformResult.ExitCode -ne 0) {
        throw "Unable to read the Terraform version: $($terraformResult.Text)"
    }
    $terraformDetails = $terraformResult.StdOutText | ConvertFrom-Json
    $rawTerraformVersion = [string]$terraformDetails.terraform_version
    if ($rawTerraformVersion.Contains('-')) {
        throw "A stable Terraform 1.7 or later release is required. Installed: $rawTerraformVersion"
    }
    $numericTerraformVersion = ($rawTerraformVersion -split '\+', 2)[0]
    if ([version]$numericTerraformVersion -lt [version]'1.7.0') {
        throw "Terraform 1.7 or later is required. Installed: $rawTerraformVersion"
    }

    $awsVersionResult = Invoke-NativeCommand -Command aws -Arguments @('--version')
    if ($awsVersionResult.ExitCode -ne 0 -or $awsVersionResult.Text -notmatch 'aws-cli/(\d+)\.') {
        throw "Unable to determine the AWS CLI version: $($awsVersionResult.Text)"
    }
    if ([int]$Matches[1] -lt 2) {
        throw "AWS CLI v2 is required. Installed: $($awsVersionResult.Text)"
    }

    $signinResult = Invoke-NativeCommand -Command aws -Arguments @(
        'signin', 'create-oauth2-token-with-iam',
        '--generate-cli-skeleton', 'input'
    )
    if ($signinResult.ExitCode -ne 0) {
        throw 'The installed AWS CLI does not support signin create-oauth2-token-with-iam. Upgrade AWS CLI v2.'
    }
}

foreach ($command in @('az', 'aws', 'terraform')) {
    Require-Command $command
}
Assert-CompatibleTools

Push-Location $PSScriptRoot
try {
    if ($identityType -eq 'UserAssigned') {
        $identity = Invoke-JsonCommand az @(
            'identity', 'show',
            '--ids', $identityResourceId,
            '--query', '{name:name,tenantId:tenantId,clientId:clientId,principalId:principalId}',
            '--output', 'json'
        )
    }
    else {
        $agentIdentity = Invoke-JsonCommand az @(
            'resource', 'show',
            '--ids', $identityResourceId,
            '--api-version', $AgentApiVersion,
            '--query', '{name:name,identityType:identity.type,tenantId:identity.tenantId,principalId:identity.principalId}',
            '--output', 'json'
        )
        $assignedIdentityTypes = @($agentIdentity.identityType -split ',' | ForEach-Object { $_.Trim() })
        if ($assignedIdentityTypes -notcontains 'SystemAssigned' -or
            [string]::IsNullOrWhiteSpace($agentIdentity.tenantId) -or
            [string]::IsNullOrWhiteSpace($agentIdentity.principalId)) {
            throw 'The selected SRE Agent does not have a ready system-assigned managed identity.'
        }

        $clientIdResult = Invoke-NativeCommand -Command az -Arguments @(
            'ad', 'sp', 'show',
            '--id', $agentIdentity.principalId,
            '--query', 'appId',
            '--output', 'tsv'
        )
        if ($clientIdResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($clientIdResult.StdOutText)) {
            throw "Unable to resolve the system identity Client ID from Entra. Verify directory read access and allow time for identity propagation. $($clientIdResult.Text)"
        }

        $identity = [PSCustomObject]@{
            name        = $agentIdentity.name
            tenantId    = $agentIdentity.tenantId
            clientId    = $clientIdResult.StdOutText.Trim()
            principalId = $agentIdentity.principalId
        }
    }
    $caller = Invoke-JsonCommand aws @(
        'sts', 'get-caller-identity',
        '--no-cli-pager',
        '--output', 'json'
    )
    if ([string]$caller.Account -notmatch '^\d{12}$' -or [string]$caller.Arn -notmatch '^arn:([^:]+):') {
        throw 'AWS returned an invalid caller identity.'
    }

    $awsPartition = $Matches[1]
    if ($awsPartition -ne 'aws') {
        throw "This setup supports the commercial AWS partition only. Active partition: $awsPartition"
    }
    $issuer = "https://login.microsoftonline.com/$($identity.tenantId)/v2.0"
    $providerPath = "login.microsoftonline.com/$($identity.tenantId)/v2.0"
    $providerArn = "arn:$awsPartition`:iam::$($caller.Account):oidc-provider/$providerPath"
    $providerResult = Invoke-NativeCommand -Command aws -Arguments @(
        'iam', 'get-open-id-connect-provider',
        '--open-id-connect-provider-arn', $providerArn,
        '--no-cli-pager',
        '--output', 'json'
    )
    $providerExists = $providerResult.ExitCode -eq 0
    if (-not $providerExists -and -not (Test-AwsNoSuchEntity $providerResult)) {
        throw "Unable to inspect the OIDC provider: $($providerResult.Text)"
    }

    $existingProviderAudiences = @()
    if ($providerExists) {
        try {
            $provider = $providerResult.StdOutText | ConvertFrom-Json
            $existingProviderAudiences = @($provider.ClientIDList)
        }
        catch {
            throw "AWS returned invalid OIDC provider JSON: $($_.Exception.Message)"
        }
    }
    $audienceExists = $existingProviderAudiences -ccontains $identity.clientId
    if (-not $audienceExists -and $existingProviderAudiences.Count -ge 100) {
        throw 'The existing IAM OIDC provider already has 100 audiences. Remove an unused audience before adding this managed identity.'
    }

    $roleResult = Invoke-NativeCommand -Command aws -Arguments @(
        'iam', 'get-role',
        '--role-name', $RoleName,
        '--no-cli-pager',
        '--output', 'json'
    )
    $roleExists = $roleResult.ExitCode -eq 0
    if (-not $roleExists -and -not (Test-AwsNoSuchEntity $roleResult)) {
        throw "Unable to inspect $RoleName`: $($roleResult.Text)"
    }

    $rolePath = '/'
    $roleDescription = 'Assumed by an Azure managed identity through Microsoft Entra OIDC federation.'
    $maxSessionDuration = 3600
    $existingRoleTrustStatements = @()
    $roleArn = "arn:$awsPartition`:iam::$($caller.Account):role/$RoleName"
    if ($roleExists) {
        try {
            $role = ($roleResult.StdOutText | ConvertFrom-Json).Role
            $roleArn = $role.Arn
            $rolePath = $role.Path
            $roleDescription = ''
            $descriptionProperty = $role.PSObject.Properties['Description']
            if ($null -ne $descriptionProperty -and -not [string]::IsNullOrWhiteSpace($descriptionProperty.Value)) {
                $roleDescription = $descriptionProperty.Value
            }
            $maxSessionDuration = $role.MaxSessionDuration
            $trustPolicy = $role.AssumeRolePolicyDocument
            if ($trustPolicy -is [string]) {
                $trustPolicy = [Uri]::UnescapeDataString($trustPolicy) | ConvertFrom-Json
            }
            if ($null -eq $trustPolicy) {
                throw 'The role does not contain an assume-role policy document.'
            }
            $existingRoleTrustStatements = @($trustPolicy.Statement)
        }
        catch {
            throw "AWS returned invalid IAM role JSON: $($_.Exception.Message)"
        }
    }

    $trustSid = "TrustManagedIdentity$($identity.clientId.Replace('-', '').ToLowerInvariant())"
    $audienceConditionKey = "$providerPath`:aud"
    $subjectConditionKey = "$providerPath`:sub"
    $existingRoleTrustStatements = @(
        foreach ($statement in $existingRoleTrustStatements) {
            $sidProperty = $statement.PSObject.Properties['Sid']
            $sid = if ($null -eq $sidProperty) { '' } else { [string]$sidProperty.Value }
            $conditionProperty = $statement.PSObject.Properties['Condition']
            $stringEqualsProperty = if ($null -eq $conditionProperty) {
                $null
            }
            elseif ($null -eq $conditionProperty.Value) {
                $null
            }
            else {
                $conditionProperty.Value.PSObject.Properties['StringEquals']
            }
            $stringEquals = if ($null -eq $stringEqualsProperty) { $null } else { $stringEqualsProperty.Value }
            $audienceProperty = if ($null -eq $stringEquals) { $null } else { $stringEquals.PSObject.Properties[$audienceConditionKey] }
            $subjectProperty = if ($null -eq $stringEquals) { $null } else { $stringEquals.PSObject.Properties[$subjectConditionKey] }
            $audienceValues = @()
            if ($null -ne $audienceProperty) {
                $audienceValues = @($audienceProperty.Value)
            }
            $subjectValues = @()
            if ($null -ne $subjectProperty) {
                $subjectValues = @($subjectProperty.Value)
            }
            $matchesIdentity = (
                $audienceValues.Count -eq 1 -and
                $subjectValues.Count -eq 1 -and
                [string]$audienceValues[0] -ceq [string]$identity.clientId -and
                [string]$subjectValues[0] -ceq [string]$identity.principalId
            )
            if ($sid -cne $trustSid -and -not $matchesIdentity) {
                $statement
            }
        }
    )

    $additionalOidcProviderAudiences = @()
    if (Test-Path -LiteralPath $GeneratedVariablesFile) {
        try {
            $existingVariables = Get-Content -LiteralPath $GeneratedVariablesFile -Raw | ConvertFrom-Json
            $property = $existingVariables.PSObject.Properties['additional_oidc_provider_audiences']
            if ($null -ne $property -and $null -ne $property.Value) {
                $additionalOidcProviderAudiences = @($property.Value)
            }
            if (-not $roleExists) {
                $property = $existingVariables.PSObject.Properties['role_path']
                if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace($property.Value)) {
                    $rolePath = $property.Value
                }
                $property = $existingVariables.PSObject.Properties['role_description']
                if ($null -ne $property -and $null -ne $property.Value) {
                    $roleDescription = [string]$property.Value
                }
                $property = $existingVariables.PSObject.Properties['max_session_duration']
                if ($null -ne $property -and $null -ne $property.Value) {
                    $maxSessionDuration = [int]$property.Value
                }
            }
        }
        catch {
            throw "Unable to read the existing $GeneratedVariablesFile file: $($_.Exception.Message)"
        }
    }
    if ($providerExists) {
        $audienceSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $additionalOidcProviderAudiences = @(
            foreach ($audience in $existingProviderAudiences) {
                if ($audience -cne $identity.clientId -and $audienceSet.Add($audience)) {
                    $audience
                }
            }
        )
    }

    $generatedVariables = [ordered]@{
        managed_identity = [ordered]@{
            type         = $identityType
            resource_id  = $identityResourceId
            name         = $identity.name
            tenant_id    = $identity.tenantId
            client_id    = $identity.clientId
            principal_id = $identity.principalId
        }
        role_name                          = $RoleName
        role_path                          = $rolePath
        role_description                   = $roleDescription
        max_session_duration               = $maxSessionDuration
        existing_role_trust_statements     = $existingRoleTrustStatements
        additional_oidc_provider_audiences = $additionalOidcProviderAudiences
        workload_policies                  = $workloadPolicies
    }
    [IO.File]::WriteAllText(
        $GeneratedVariablesFile,
        ($generatedVariables | ConvertTo-Json -Depth 100),
        [Text.UTF8Encoding]::new($false)
    )

    Write-Host ''
    Write-Host 'Discovered Azure identity' -ForegroundColor Cyan
    Write-Host "  Identity type:    $identityType"
    Write-Host "  Managed identity: $($identity.name)"
    Write-Host "  Tenant ID:        $($identity.tenantId)"
    Write-Host "  Client ID:        $($identity.clientId)"
    Write-Host "  Principal ID:     $($identity.principalId)"
    Write-Host "  AWS account ID:   $($caller.Account)"
    Write-Host "  OIDC provider:    $providerArn"
    Write-Host ''
    Write-Host 'Terraform will manage:' -ForegroundColor Cyan
    Write-Host "  Microsoft Entra OIDC provider: $(if ($providerExists) { 'existing; import into this Terraform state' } else { 'create' })"
    Write-Host "  Managed identity audience: $(if ($audienceExists) { 'already present' } else { 'add' })"
    Write-Host "  IAM role: $RoleName ($(if ($roleExists) { 'existing; preserve current trust and add this identity' } else { 'create' }))"
    Write-Host '  AWS MCP OAuth managed policy attachment'
    Write-Host "  Inline policies: $policySource"
    Write-Host ''

    $terraformResult = Invoke-NativeCommand -Command terraform -Arguments @('init', '-input=false', '-no-color')
    if ($terraformResult.ExitCode -ne 0) {
        Write-Host $terraformResult.Text
        throw 'terraform init failed.'
    }

    $providerInState = Test-TerraformStateAddress 'aws_iam_openid_connect_provider.entra'
    if ($providerInState) {
        Assert-TerraformStateBinding `
            -Address 'aws_iam_openid_connect_provider.entra' `
            -ExpectedArn $providerArn
    }
    elseif ($providerExists) {
            Write-Host 'Importing the existing OIDC provider into the local Terraform state...'
            $terraformResult = Invoke-NativeCommand -Command terraform -Arguments @(
                'import', '-input=false', '-no-color',
                'aws_iam_openid_connect_provider.entra', $providerArn
            )
            if ($terraformResult.ExitCode -ne 0) {
                Write-Host $terraformResult.Text
                throw 'Unable to import the existing OIDC provider.'
            }
    }

    $roleInState = Test-TerraformStateAddress 'aws_iam_role.entra'
    if ($roleInState -and $roleExists) {
        Assert-TerraformStateBinding `
            -Address 'aws_iam_role.entra' `
            -ExpectedArn $roleArn
    }
    elseif ($roleExists) {
        Write-Host "Importing the existing $RoleName role into the local Terraform state..."
        $terraformResult = Invoke-NativeCommand -Command terraform -Arguments @(
            'import', '-input=false', '-no-color',
            'aws_iam_role.entra', $RoleName
        )
        if ($terraformResult.ExitCode -ne 0) {
            Write-Host $terraformResult.Text
            throw "Unable to import the existing $RoleName role."
        }
    }

    $terraformResult = Invoke-NativeCommand -Command terraform -Arguments @(
        'plan', '-input=false', '-no-color', "-out=$PlanFile"
    )
    if ($terraformResult.ExitCode -ne 0) {
        Write-Host $terraformResult.Text
        throw 'terraform plan failed. Review the Terraform output and the local state before rerunning.'
    }

    Write-Host ''
    if ($SkipApproval -ieq 'false') {
        $confirmation = (Read-Host 'Proceed with these AWS changes? [y/n]').Trim().ToLowerInvariant()
        if ($confirmation -ne 'y') {
            Write-Host 'No AWS changes were applied.'
            Remove-Item -LiteralPath $PlanFile -Force -ErrorAction SilentlyContinue
            exit 0
        }
    }
    else {
        Write-Host 'skip-approval=true; applying without confirmation.'
    }

    $applyExitCode = Invoke-NativeStreamingCommand -Command terraform -Arguments @(
        'apply', '-input=false', '-auto-approve', $PlanFile
    )
    if ($applyExitCode -ne 0) {
        throw 'terraform apply failed.'
    }
    Remove-Item -LiteralPath $PlanFile -Force -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Host 'AWS setup completed.' -ForegroundColor Green
    Write-Host "Role: $RoleName"
    Write-Host ''
    Write-Host "To review the SRE Agent inline policies, open IAM > Roles > $RoleName > Permissions in the AWS Console: $policySource."
}
finally {
    Pop-Location
}
