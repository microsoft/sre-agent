# Invoke-Jq.ps1 — Safe jq wrapper for PowerShell 7.3+
#
# PowerShell 7.3+ changed native-command argument passing in ways that break
# complex jq filters containing commas, // (alternative operator), semicolons,
# or --argjson values. Even with $PSNativeCommandArgumentPassing = 'Legacy',
# these constructs are unreliable.
#
# This module provides Invoke-Jq which writes the filter to a temp file and
# uses `jq -f`, completely bypassing PS argument mangling.
#
# Usage:
#   . (Join-Path $PSScriptRoot 'Invoke-Jq.ps1')
#   $result = $json | Invoke-Jq -Raw -Filter '.upgradeChannel // "Preview"'
#   $result = $json | Invoke-Jq -Compact -Filter '.connectors // []'
#   $result = Invoke-Jq -Filter '.name' -ExtraArgs @('--arg', 'x', $val) -InputFile $file

function Invoke-Jq {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Filter,

        [Parameter(ValueFromPipeline)]
        [string]$InputJson,

        [string[]]$ExtraArgs = @(),

        [string]$InputFile,

        [switch]$Compact,
        [switch]$Raw,
        [switch]$Slurp,
        [switch]$ExitTest    # like jq -e
    )
    process {
        $tmpFilter = [System.IO.Path]::GetTempFileName()
        try {
            Set-Content -Path $tmpFilter -Value $Filter -NoNewline -Encoding UTF8
            $flags = @('-f', $tmpFilter)
            if ($Compact)  { $flags += '-c' }
            if ($Raw)      { $flags += '-r' }
            if ($Slurp)    { $flags += '-s' }
            if ($ExitTest) { $flags += '-e' }
            $flags += $ExtraArgs

            if ($InputFile) {
                return (jq @flags $InputFile)
            }
            elseif ($InputJson) {
                return ($InputJson | jq @flags)
            }
            else {
                return (jq @flags)
            }
        }
        finally {
            Remove-Item $tmpFilter -ErrorAction SilentlyContinue
        }
    }
}

# Invoke-JqSlurpFile — safe alternative to --argjson that passes JSON via --slurpfile
# Usage: $result = $json | Invoke-JqSlurpFile -VarName 'i' -JsonValue $itemJson -Filter '. + [$i[0]]' -Compact
function Invoke-JqSlurpFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Filter,
        [Parameter(Mandatory)][string]$VarName,
        [Parameter(Mandatory)][string]$JsonValue,
        [Parameter(ValueFromPipeline)][string]$InputJson,
        [switch]$Compact,
        [switch]$Raw
    )
    process {
        $tmpJson = [System.IO.Path]::GetTempFileName()
        try {
            Set-Content -Path $tmpJson -Value $JsonValue -NoNewline -Encoding UTF8
            $extra = @('--slurpfile', $VarName, $tmpJson)
            if ($InputJson) {
                return ($InputJson | Invoke-Jq -Filter $Filter -ExtraArgs $extra -Compact:$Compact -Raw:$Raw)
            }
            else {
                return (Invoke-Jq -Filter $Filter -ExtraArgs $extra -Compact:$Compact -Raw:$Raw)
            }
        }
        finally {
            Remove-Item $tmpJson -ErrorAction SilentlyContinue
        }
    }
}
