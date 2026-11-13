[CmdletBinding()]
param([string]$ConfigPath, [string]$OverridePath, [switch]$AsJson)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Config.psm1') -Force
try {
    $config = Read-MonitorConfig -Path $ConfigPath -OverridePath $OverridePath
    $result = [pscustomobject]@{ Valid = $true; Profile = $config.Profile; Binding = '127.0.0.1'; Errors = @() }
    if ($AsJson) { $result | ConvertTo-Json -Depth 3 } else { $result }
    exit 0
} catch {
    $result = [pscustomobject]@{ Valid = $false; Errors = @($_.Exception.Message) }
    if ($AsJson) { $result | ConvertTo-Json -Depth 3 } else { Write-Error $result.Errors[0] -ErrorAction Continue }
    exit 2
}
