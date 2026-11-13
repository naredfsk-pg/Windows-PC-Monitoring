[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param([Parameter(Mandatory = $true)][string]$BackupPath, [string]$ConfigPath, [string]$OverridePath, [switch]$Apply, [switch]$AsJson)
$ErrorActionPreference = 'Stop'
$stage = 'configuration'
try {
    Import-Module (Join-Path $PSScriptRoot 'lib/Config.psm1')
    Import-Module (Join-Path $PSScriptRoot 'lib/Services.psm1')
    $config = Read-MonitorConfig -Path $ConfigPath -OverridePath $OverridePath
    $installation = Get-MonitorInstallation -Config $config
    if (-not $installation) { throw 'Restore requires an existing verified same-version installation. Prepare a separate installation before a restore drill.' }
    $plan = Get-MonitorRestorePlan -Config $config -Installation $installation -BackupPath $BackupPath
    $result = $plan | Select-Object SchemaVersion,Mode,Operation,BackupPath,DestinationPath,FileCount,StagingBytes,SecretFilesIncluded,Note
    if ($Apply -and -not $WhatIfPreference) {
        $stage = 'apply'
        if ($PSCmdlet.ShouldProcess($config.DataRoot, 'Restore same-version backup and retain current state for rollback; interrupt owned services')) {
            $result = Invoke-MonitorRestore -Config $config -Installation $installation -BackupPath $BackupPath -Confirm:$false
        }
    } elseif ($WhatIfPreference) { $null = $PSCmdlet.ShouldProcess($config.DataRoot, 'Restore a verified compatible backup') }
    if ($AsJson) { $result | ConvertTo-Json -Depth 5 } else { $result }
    exit 0
} catch {
    $message = $_.Exception.Message
    $result = [pscustomobject]@{ SchemaVersion = 1; Success = $false; ErrorCode = 'RESTORE_FAILED'; Message = $message }
    if ($AsJson) { $result | ConvertTo-Json } else { $result }
    if ($message -like 'ADMIN_REQUIRED:*') { exit 3 }; if ($stage -eq 'configuration') { exit 2 }; exit 1
}
