[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$ConfigPath,
    [string]$OverridePath,
    [string]$CachePath,
    [Security.SecureString]$GrafanaAdminPassword,
    [switch]$Apply,
    [switch]$AsJson
)
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$stage = 'configuration'
try {
    Import-Module (Join-Path $PSScriptRoot 'lib/Config.psm1')
    Import-Module (Join-Path $PSScriptRoot 'lib/Artifacts.psm1')
    Import-Module (Join-Path $PSScriptRoot 'lib/Services.psm1')
    $config = Read-MonitorConfig -Path $ConfigPath -OverridePath $OverridePath
    $manifest = Read-MonitorManifest -Path (Join-Path $repositoryRoot 'config/dependencies.lock.json')
    if (-not $CachePath) { $CachePath = Join-Path $repositoryRoot 'downloads' }
    $plan = Get-MonitorInstallPlan -Config $config -Manifest $manifest -RepositoryRoot $repositoryRoot
    $result = $plan
    if ($Apply -and -not $WhatIfPreference) {
        $stage = 'apply'
        if ($PSCmdlet.ShouldProcess(($config.InstallRoot + '; ' + $config.DataRoot), 'Apply the reviewed PC Monitor installation plan')) {
            $result = Invoke-MonitorInstall -Config $config -Manifest $manifest -RepositoryRoot $repositoryRoot -CachePath $CachePath -GrafanaAdminPassword $GrafanaAdminPassword -Confirm:$false
        }
    } elseif ($WhatIfPreference) {
        $null = $PSCmdlet.ShouldProcess(($config.InstallRoot + '; ' + $config.DataRoot), 'Install PC Monitor; no downloads or host changes in WhatIf mode')
    }
    if ($AsJson) { $result | ConvertTo-Json -Depth 10 } else { $result }
    exit 0
} catch {
    $message = [regex]::Replace($_.Exception.Message, 'eyJ[A-Za-z0-9_\-\.=]{40,}', '<redacted>')
    $exitCode = if ($message -like 'ADMIN_REQUIRED:*') { 3 } elseif ($stage -eq 'configuration') { 2 } else { 1 }
    $result = [pscustomobject]@{ SchemaVersion = 1; Success = $false; ErrorCode = 'INSTALL_FAILED'; Message = $message }
    if ($AsJson) { $result | ConvertTo-Json } else { $result }
    exit $exitCode
}
