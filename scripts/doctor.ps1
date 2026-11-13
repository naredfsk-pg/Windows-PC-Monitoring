[CmdletBinding()]
param([string]$ConfigPath, [string]$OverridePath, [switch]$AsJson)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Config.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/Diagnostics.psm1') -Force
try {
    $config = Read-MonitorConfig -Path $ConfigPath -OverridePath $OverridePath
    $result = Get-MonitorStatus -Config $config -Detailed
    if ($AsJson) { $result | ConvertTo-Json -Depth 6 } else { $result.Checks | Format-Table Name, State, Detail -Wrap; Write-Output ('Overall: ' + $result.OverallState) }
    if ($result.OverallState -in @('Healthy', 'Degraded')) { exit 0 }
    exit 1
} catch { Write-Error 'Doctor could not evaluate this installation. Validate configuration and check read permissions.' -ErrorAction Continue; exit 2 }
