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
if ($source -notmatch [regex]::Escape("`$etag = '*'")) {
    throw 'Tool-permission updates must fall back to If-Match: * when settings have no ETag.'
}
if ($source -match 'A single strong ETag is required') {
    throw 'Tool-permission updates must not require an ETag that the bootstrap endpoint can omit.'
}
Write-Host 'PASS: skill arrays are preserved and tool permissions support settings without an ETag.'
