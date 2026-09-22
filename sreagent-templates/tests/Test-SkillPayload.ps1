#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '..\bicep\Apply-Extras.ps1'
$source = Get-Content -LiteralPath $path -Raw
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path $path).Path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Apply-Extras did not parse.' }
$assignment = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -eq '$props' -and
    $node.Right.Extent.Text -match 'skillContent'
}, $true)
if (-not $assignment) { throw 'Skill payload assignment not found.' }
foreach ($tools in @(@(), @('ReadFile'), @('ReadFile', 'ListDir'))) {
    $sk = [pscustomobject]@{
        metadata = [pscustomobject]@{ description = 'test'; spec = [pscustomobject]@{ tools = $tools } }
        skillContent = '# Test'
        additionalFiles = @()
    }
    $name = 'test'
    # Evaluate only the actual payload assignment, never the deployment script.
    $props = $null
    Invoke-Expression $assignment.Extent.Text
    $json = $props | ConvertTo-Json -Depth 10
    $payload = $json | ConvertFrom-Json -AsHashtable
    if ($payload.tools -isnot [array] -or $payload.tools.Count -ne $tools.Count) {
        throw "Skill tools lost array shape for $($tools.Count) tool(s)."
    }
    if ($payload.additionalFiles -isnot [array] -or $payload.additionalFiles.Count -ne 0) {
        throw 'Empty additionalFiles must remain an array.'
    }
}
$etagFunction = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Get-SafeETag'
}, $true)
if (-not $etagFunction) { throw 'Get-SafeETag function not found.' }
Invoke-Expression $etagFunction.Extent.Text
$etagCases = @(
    @{ Name = 'missing'; Response = [pscustomobject]@{ Headers = [pscustomobject]@{} }; Expected = '*' }
    @{ Name = 'empty'; Response = [pscustomobject]@{ Headers = [pscustomobject]@{ ETag = '' } }; Expected = '*' }
    @{ Name = 'whitespace'; Response = [pscustomobject]@{ Headers = [pscustomobject]@{ ETag = '  ' } }; Expected = '*' }
    @{ Name = 'valid'; Response = [pscustomobject]@{ Headers = [pscustomobject]@{ ETag = '"valid"' } }; Expected = '"valid"' }
    @{ Name = 'multiline'; Response = [pscustomobject]@{ Headers = [pscustomobject]@{ ETag = "bad`r`nvalue" } }; Expected = '*' }
)
foreach ($etagCase in $etagCases) {
    $actual = Get-SafeETag -Response $etagCase.Response
    if ($actual -ne $etagCase.Expected) {
        throw "Unexpected ETag for $($etagCase.Name): $actual"
    }
}
if ($source -match 'A single strong ETag is required') {
    throw 'Tool-permission updates must not require an ETag that the bootstrap endpoint can omit.'
}
if ($source -match '\.Headers\.Contains\(' -or $source -match '\.Headers\.GetValues\(') {
    throw 'Tool-permission updates must not depend on header methods missing from some PowerShell response objects.'
}
if ($source -notmatch [regex]::Escape("'400', '405'")) {
    throw 'Knowledge retries must confirm existing sources after HTTP 400 or 405.'
}
Write-Host 'PASS: skill arrays are preserved and tool permissions safely fall back when ETag is missing or invalid.'
