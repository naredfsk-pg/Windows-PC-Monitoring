[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param([string]$ConfigPath, [string]$OverridePath, [switch]$RemoveBinaries, [switch]$PurgeData, [switch]$Apply, [switch]$AsJson)
$ErrorActionPreference = 'Stop'
$stage = 'configuration'
try {
    Import-Module (Join-Path $PSScriptRoot 'lib/Config.psm1')
    Import-Module (Join-Path $PSScriptRoot 'lib/Services.psm1')
    $config = Read-MonitorConfig -Path $ConfigPath -OverridePath $OverridePath
    $installation = Get-MonitorInstallation -Config $config
    if (-not $installation) { throw 'No owned installation metadata found; no services or directories will be removed.' }
    Assert-MonitorOwnedServices -Config $config -Installation $installation -AllowMissing
    $result = [pscustomobject]@{
        SchemaVersion = 1; Mode = 'PlanOnly'; Operation = 'Uninstall'; Services = @($installation.Services.Name)
        InstallRoot = $config.InstallRoot; DataRoot = $config.DataRoot
        RemoveBinaries = [bool]$RemoveBinaries; PurgeData = [bool]$PurgeData
    }
    if ($Apply -and -not $WhatIfPreference) {
        $stage = 'apply'
        $action = 'Remove owned services; RemoveBinaries=' + [bool]$RemoveBinaries + '; PermanentlyPurgeDataAndSecrets=' + [bool]$PurgeData
        if ($PSCmdlet.ShouldProcess(($config.InstallRoot + '; ' + $config.DataRoot), $action)) {
            Invoke-MonitorUninstall -Config $config -Installation $installation -RepositoryRoot (Split-Path -Parent $PSScriptRoot) -RemoveBinaries:$RemoveBinaries -PurgeData:$PurgeData -Confirm:$false
            $result.Mode = 'Applied'
        }
    } elseif ($WhatIfPreference) { $null = $PSCmdlet.ShouldProcess(($config.InstallRoot + '; ' + $config.DataRoot), 'Remove owned services and only explicitly selected directories') }
    if ($AsJson) { $result | ConvertTo-Json -Depth 4 } else { $result }
    exit 0
} catch {
    $message = $_.Exception.Message
    $result = [pscustomobject]@{ SchemaVersion = 1; Success = $false; ErrorCode = 'UNINSTALL_FAILED'; Message = $message }
    if ($AsJson) { $result | ConvertTo-Json } else { $result }
    if ($message -like 'ADMIN_REQUIRED:*') { exit 3 }; if ($stage -eq 'configuration') { exit 2 }; exit 1
}
