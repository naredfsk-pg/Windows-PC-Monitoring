[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param([Parameter(Mandatory = $true)][string]$DestinationPath, [string]$ConfigPath, [string]$OverridePath, [switch]$Apply, [switch]$AsJson)
$ErrorActionPreference = 'Stop'
$stage = 'configuration'
try {
    Import-Module (Join-Path $PSScriptRoot 'lib/Config.psm1')
    Import-Module (Join-Path $PSScriptRoot 'lib/Services.psm1')
    $config = Read-MonitorConfig -Path $ConfigPath -OverridePath $OverridePath
    $installation = Get-MonitorInstallation -Config $config
    if (-not $installation) { throw 'No owned installation metadata found; a consistent service-aware backup cannot be created.' }
    $result = Get-MonitorBackupPlan -Config $config -Installation $installation -DestinationPath $DestinationPath
    if ($Apply -and -not $WhatIfPreference) {
        $stage = 'apply'
        if ($PSCmdlet.ShouldProcess($result.DestinationPath, 'Interrupt owned services and create a protected backup without secret files')) {
            $result = Invoke-MonitorBackup -Config $config -Installation $installation -DestinationPath $DestinationPath -Confirm:$false
        }
    } elseif ($WhatIfPreference) { $null = $PSCmdlet.ShouldProcess($result.DestinationPath, 'Create protected service-consistent backup') }
    if ($AsJson) { $result | ConvertTo-Json -Depth 5 } else { $result }
    exit 0
} catch {
    $message = $_.Exception.Message
    $result = [pscustomobject]@{ SchemaVersion = 1; Success = $false; ErrorCode = 'BACKUP_FAILED'; Message = $message }
    if ($AsJson) { $result | ConvertTo-Json } else { $result }
    if ($message -like 'ADMIN_REQUIRED:*') { exit 3 }; if ($stage -eq 'configuration') { exit 2 }; exit 1
}
