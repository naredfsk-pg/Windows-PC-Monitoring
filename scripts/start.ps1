[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param([string]$ConfigPath, [string]$OverridePath, [switch]$Apply, [switch]$AsJson)
$ErrorActionPreference = 'Stop'
$stage = 'configuration'
try {
    Import-Module (Join-Path $PSScriptRoot 'lib/Config.psm1')
    Import-Module (Join-Path $PSScriptRoot 'lib/Services.psm1')
    $config = Read-MonitorConfig -Path $ConfigPath -OverridePath $OverridePath
    $installation = Get-MonitorInstallation -Config $config
    if (-not $installation) { throw 'No owned installation metadata found. Run install.ps1 to prepare an installation plan.' }
    Assert-MonitorOwnedServices -Config $config -Installation $installation
    $result = [pscustomobject]@{ SchemaVersion = 1; Mode = 'PlanOnly'; Operation = 'Start'; Services = @($installation.Services.Name) }
    if ($Apply -and -not $WhatIfPreference) {
        $stage = 'apply'
        if ($PSCmdlet.ShouldProcess(($installation.Services.Name -join ', '), 'Start owned monitoring services and check readiness')) {
            Invoke-MonitorServiceOperation -Operation Start -Config $config -Installation $installation -Confirm:$false
            $result.Mode = 'Applied'
        }
    } elseif ($WhatIfPreference) { $null = $PSCmdlet.ShouldProcess(($installation.Services.Name -join ', '), 'Start owned monitoring services') }
    if ($AsJson) { $result | ConvertTo-Json -Depth 4 } else { $result }
    exit 0
} catch {
    $message = $_.Exception.Message
    $result = [pscustomobject]@{ SchemaVersion = 1; Success = $false; ErrorCode = 'START_FAILED'; Message = $message }
    if ($AsJson) { $result | ConvertTo-Json } else { $result }
    if ($message -like 'ADMIN_REQUIRED:*') { exit 3 }; if ($stage -eq 'configuration') { exit 2 }; exit 1
}
