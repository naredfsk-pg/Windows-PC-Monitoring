Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Artifacts.psm1')
Import-Module (Join-Path $PSScriptRoot 'Config.psm1')
Import-Module (Join-Path $PSScriptRoot 'Secrets.psm1')

function Get-MonitorInstallPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory = $true)]$Manifest,
        [string]$RepositoryRoot = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
    )
    $validation = Test-MonitorConfig -Config $Config
    if (-not $validation.Valid) { throw ('Invalid monitor configuration: ' + ($validation.Errors -join ' ')) }
    Assert-MonitorSafeDirectory -Path $Config.InstallRoot -RepositoryRoot $RepositoryRoot
    Assert-MonitorSafeDirectory -Path $Config.DataRoot -RepositoryRoot $RepositoryRoot
    $services = @()
    foreach ($entry in @(
        @{ Name = 'PCMonitor-Exporter'; Component = 'windows_exporter'; Account = 'LocalSystem'; Port = $Config.ExporterPort },
        @{ Name = 'PCMonitor-Prometheus'; Component = 'prometheus'; Account = 'NT AUTHORITY\LocalService'; Port = $Config.PrometheusPort },
        @{ Name = 'PCMonitor-Grafana'; Component = 'grafana'; Account = 'NT AUTHORITY\LocalService'; Port = $Config.GrafanaPort }
    )) {
        $component = @($Manifest.components | Where-Object id -eq $entry.Component)[0]
        $services += [pscustomobject]@{
            Name = $entry.Name; Component = $entry.Component; Account = $entry.Account; Port = $entry.Port
            WrapperPath = (Join-Path (Join-Path $Config.InstallRoot 'services') ($entry.Name + '.exe'))
            ExecutablePath = (Join-Path (Join-Path (Join-Path $Config.InstallRoot $component.id) $component.version) $component.executableRelativePath)
        }
    }
    $checks = New-Object 'System.Collections.Generic.List[object]'
    $isX64 = $env:PROCESSOR_ARCHITECTURE -eq 'AMD64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'AMD64'
    $checks.Add([pscustomobject]@{ Name = 'Architecture'; Passed = $isX64; Detail = 'Windows x64 is required.' })
    $dotNetReady = $false
    try { $dotNetReady = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop).Release -ge 394254 } catch { }
    $checks.Add([pscustomobject]@{ Name = 'DotNetFramework'; Passed = $dotNetReady; Detail = 'WinSW requires preinstalled .NET Framework 4.6.1 or newer; 4.8 is recommended.' })
    $checks.Add([pscustomobject]@{ Name = 'Tar'; Passed = [bool](Get-Command tar.exe -ErrorAction SilentlyContinue); Detail = 'Windows tar.exe is needed for the pinned Grafana archive.' })
    $installation = Get-MonitorInstallation -Config $Config
    foreach ($service in $services) {
        $existing = Get-Service -Name $service.Name -ErrorAction SilentlyContinue
        $owned = $false
        if ($installation -and $existing) {
            try { Assert-MonitorOwnedServices -Config $Config -Installation $installation; $owned = $true } catch { }
        }
        $available = -not [bool]$existing -or $owned
        $checks.Add([pscustomobject]@{ Name = $service.Name; Passed = $available; Detail = 'Existing service names require matching protected installation metadata and executable paths.' })
    }
    if (-not $installation) {
        $listeners = @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners())
        foreach ($service in $services) {
            $checks.Add([pscustomobject]@{ Name = ('Port' + $service.Port); Passed = (@($listeners | Where-Object Port -eq $service.Port).Count -eq 0); Detail = 'The configured service port must be available for a fresh installation.' })
        }
    }
    return [pscustomobject]@{
        SchemaVersion = 1; TimestampUtc = [DateTime]::UtcNow.ToString('o'); Mode = 'PlanOnly'
        InstallRoot = $Config.InstallRoot; DataRoot = $Config.DataRoot; Binding = '127.0.0.1'
        Profile = $Config.Profile; Services = $services; Components = $Manifest.components
        Checks = $checks.ToArray(); CanApply = (@($checks | Where-Object { -not $_.Passed }).Count -eq 0)
        ExistingInstallation = [bool]$installation
        ProtectedSecretNames = @('GrafanaAdminPassword')
        ExcludedActions = @('cloudflared changes', 'Cloudflare routes/DNS/Access', 'firewall changes', 'reboot', 'SMTP sending')
        RuntimeValidation = 'Pending: execution policy, service identities, actual metrics, dashboard readiness, and reboot/no-login verification.'
    }
}

function Get-MonitorInstallation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Config)
    $metadataPath = Join-Path $Config.DataRoot 'installation.json'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { return $null }
    Assert-MonitorNoReparsePoint -Path $metadataPath
    Assert-MonitorProtectedMetadata -Path $metadataPath
    try { $installation = Get-Content -Raw -LiteralPath $metadataPath -Encoding UTF8 | ConvertFrom-Json } catch { throw 'Installation metadata is unreadable; existing services will not be changed.' }
    if ($installation.SchemaVersion -ne 1 -or $installation.InstallRoot -ine $Config.InstallRoot -or $installation.DataRoot -ine $Config.DataRoot) { throw 'Installation metadata does not match the configured owned roots.' }
    $expected = @('PCMonitor-Exporter', 'PCMonitor-Prometheus', 'PCMonitor-Grafana')
    if (@($installation.Services).Count -ne 3 -or @($installation.Services.Name | Select-Object -Unique).Count -ne 3) { throw 'Installation metadata contains an invalid service inventory.' }
    foreach ($service in $installation.Services) {
        $expectedPath = Join-Path (Join-Path $Config.InstallRoot 'services') ($service.Name + '.exe')
        if ($service.Name -notin $expected -or $service.WrapperPath -ine $expectedPath) { throw 'Installation service inventory does not match the dedicated service directory.' }
    }
    return $installation
}

function Assert-MonitorOwnedServices {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory = $true)]$Installation,
        [switch]$AllowMissing
    )
    if ($Installation.InstallRoot -ine $Config.InstallRoot -or $Installation.DataRoot -ine $Config.DataRoot) { throw 'Installation ownership roots do not match.' }
    foreach ($service in $Installation.Services) {
        $expected = Join-Path (Join-Path $Config.InstallRoot 'services') ($service.Name + '.exe')
        if ($service.Name -notin @('PCMonitor-Exporter', 'PCMonitor-Prometheus', 'PCMonitor-Grafana') -or $service.WrapperPath -ine $expected) { throw 'Refusing a service outside the protected installation inventory.' }
        $existing = Get-Service -Name $service.Name -ErrorAction SilentlyContinue
        if (-not $existing) {
            if ($AllowMissing) { continue }
            throw ('Required owned service is missing: ' + $service.Name)
        }
        $registryPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $service.Name
        try { $imagePath = [string](Get-ItemProperty -LiteralPath $registryPath -Name ImagePath -ErrorAction Stop).ImagePath } catch { throw ('Unable to verify the executable path for ' + $service.Name) }
        if ($imagePath.Trim() -ine $expected -and $imagePath.Trim() -ine ('"' + $expected + '"')) { throw ('Executable-path ownership check failed for ' + $service.Name) }
        Assert-MonitorNoReparsePoint -Path $expected
        $wrapper = @($Installation.Components | Where-Object id -eq 'winsw')
        if ($wrapper.Count -ne 1) { throw 'Installation metadata is missing the wrapper hash.' }
        Assert-MonitorArtifactHash -Path $expected -ExpectedSha256 $wrapper[0].sha256
    }
}

function Invoke-MonitorInstall {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$CachePath,
        [Security.SecureString]$GrafanaAdminPassword
    )
    $plan = Get-MonitorInstallPlan -Config $Config -Manifest $Manifest -RepositoryRoot $RepositoryRoot
    if (-not $PSCmdlet.ShouldProcess(($Config.InstallRoot + '; ' + $Config.DataRoot), 'Install the three owned localhost monitoring services')) { return $plan }
    Assert-MonitorAdministrator
    if (-not $plan.CanApply) { throw 'Installation prerequisites failed. Review the plan Checks before applying.' }
    $installation = Get-MonitorInstallation -Config $Config
    if ($installation) {
        Assert-MonitorMatchingInstallation -Config $Config -Manifest $Manifest -Installation $installation
        Assert-MonitorOwnedServices -Config $Config -Installation $installation
        if ($GrafanaAdminPassword) { throw 'An existing Grafana password is never reset by reinstalling. Use Grafana account management for password changes.' }
        $existingSecret = Get-MonitorSecret -Name GrafanaAdminPassword -DataRoot $Config.DataRoot
        $existingSecret.Dispose()
        return [pscustomobject]@{ SchemaVersion = 1; Changed = $false; State = 'AlreadyInstalled'; Detail = 'Same-version rerun preserved existing configuration, secrets and history. Use start.ps1 for stopped services.' }
    }
    foreach ($root in @($Config.InstallRoot, $Config.DataRoot)) {
        if ((Test-Path -LiteralPath $root) -and @(Get-ChildItem -LiteralPath $root -Force).Count -gt 0) { throw 'Fresh installation requires empty dedicated roots. Unowned or incomplete installation contents will not be overwritten.' }
    }
    $stagingRoot = Join-Path ([IO.Path]::GetFullPath($CachePath)) ('staging-' + [Guid]::NewGuid().ToString('N'))
    $staged = @{}
    foreach ($component in $Manifest.components) {
        $artifact = Get-MonitorArtifact -Component $component -CachePath $CachePath -Confirm:$false
        $destination = Join-Path $stagingRoot $component.id
        $staged[$component.id] = Expand-MonitorArtifact -Component $component -ArtifactPath $artifact -DestinationPath $destination -Confirm:$false
    }
    # Application Control and binary compatibility must fail before any service/ACL/root mutation.
    foreach ($componentId in @('windows_exporter', 'prometheus', 'grafana')) {
        $component = @($Manifest.components | Where-Object id -eq $componentId)[0]
        $binary = Join-Path $staged[$componentId] $component.executableRelativePath
        Invoke-MonitorBinaryPreflight -Path $binary -ComponentId $componentId
    }
    $registered = New-Object 'System.Collections.Generic.List[object]'
    $phase = 'prepare-owned-directories'
    try {
        foreach ($root in @($Config.InstallRoot, $Config.DataRoot)) {
            $null = [IO.Directory]::CreateDirectory($root)
            Set-MonitorDirectoryAcl -Path $root -LocalServiceRights ReadAndExecute
        }
        foreach ($relative in @('config', 'data', 'logs', 'secrets')) {
            $path = Join-Path $Config.DataRoot $relative
            $null = [IO.Directory]::CreateDirectory($path)
            Set-MonitorDirectoryAcl -Path $path -LocalServiceRights ReadAndExecute
        }
        foreach ($relative in @('data/prometheus', 'data/grafana', 'logs/prometheus', 'logs/grafana', 'logs/windows_exporter')) {
            $path = Join-Path $Config.DataRoot $relative
            $null = [IO.Directory]::CreateDirectory($path)
            Set-MonitorDirectoryAcl -Path $path -LocalServiceRights Modify
        }
        foreach ($component in $Manifest.components) {
            $target = Join-Path (Join-Path $Config.InstallRoot $component.id) $component.version
            $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $target))
            Copy-Item -LiteralPath $staged[$component.id] -Destination $target -Recurse -ErrorAction Stop
        }
        $phase = 'render-and-validate-configuration'
        $null = Write-MonitorConfiguration -Config $Config -OutputPath (Join-Path $Config.DataRoot 'config') -RepositoryRoot $RepositoryRoot -Confirm:$false
        $exporter = @($plan.Services | Where-Object Component -eq 'windows_exporter')[0]
        Invoke-MonitorNative -Path $exporter.ExecutablePath -Arguments @('--config.file', (Join-Path $Config.DataRoot 'config/exporters/windows_exporter.yml'), '--scrape.stdout') -FailureMessage 'Exporter configuration/collector preflight failed; no service has been installed.'
        $prometheus = @($plan.Services | Where-Object Component -eq 'prometheus')[0]
        Invoke-MonitorNative -Path (Join-Path (Split-Path -Parent $prometheus.ExecutablePath) 'promtool.exe') -Arguments @('check', 'config', (Join-Path $Config.DataRoot 'config/prometheus/prometheus.yml')) -FailureMessage 'Prometheus configuration preflight failed; no service has been installed.'
        $phase = 'provision-bootstrap-secret'
        $secretPath = Get-MonitorSecretPath -Name GrafanaAdminPassword -DataRoot $Config.DataRoot
        if (-not (Test-Path -LiteralPath $secretPath)) {
            $random = New-Object byte[] 32
            if ($GrafanaAdminPassword) {
                $securePassword = $GrafanaAdminPassword.Copy()
            } else {
                $generator = New-Object Security.Cryptography.RNGCryptoServiceProvider
                try { $generator.GetBytes($random) } finally { $generator.Dispose() }
                $securePassword = ConvertTo-SecureString -String ([Convert]::ToBase64String($random)) -AsPlainText -Force
            }
            try { Set-MonitorSecret -Name GrafanaAdminPassword -Value $securePassword -DataRoot $Config.DataRoot -Confirm:$false } finally { $securePassword.Dispose(); [Array]::Clear($random, 0, $random.Length) }
        } else {
            $existingSecret = Get-MonitorSecret -Name GrafanaAdminPassword -DataRoot $Config.DataRoot
            $existingSecret.Dispose()
        }
        $phase = 'register-services'
        $serviceRoot = Join-Path $Config.InstallRoot 'services'
        $null = [IO.Directory]::CreateDirectory($serviceRoot)
        $wrapper = @($Manifest.components | Where-Object id -eq 'winsw')[0]
        $wrapperSource = Join-Path (Join-Path (Join-Path $Config.InstallRoot 'winsw') $wrapper.version) $wrapper.executableRelativePath
        foreach ($service in $plan.Services) {
            Copy-Item -LiteralPath $wrapperSource -Destination $service.WrapperPath -ErrorAction Stop
            Write-MonitorServiceXml -Service $service -Config $Config
            $registered.Add($service)
            Invoke-MonitorNative -Path $service.WrapperPath -Arguments @('install') -FailureMessage ('Service registration failed: ' + $service.Name)
        }
        $phase = 'start-and-check-readiness'
        foreach ($service in $plan.Services) {
            Invoke-MonitorNative -Path $service.WrapperPath -Arguments @('start') -FailureMessage ('Service startup failed: ' + $service.Name)
            (Get-Service -Name $service.Name).WaitForStatus('Running', [TimeSpan]::FromSeconds(40))
        }
        Wait-MonitorReadiness -Config $Config
        $phase = 'commit-installation-metadata'
        $metadata = [ordered]@{
            SchemaVersion = 1; State = 'Installed'; TimestampUtc = [DateTime]::UtcNow.ToString('o')
            InstallRoot = $Config.InstallRoot; DataRoot = $Config.DataRoot; Config = $Config
            Components = $Manifest.components; Services = $plan.Services
        }
        $metadataPath = Join-Path $Config.DataRoot 'installation.json'
        [IO.File]::WriteAllText($metadataPath, ($metadata | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        $metadataAcl = Get-Acl -LiteralPath $metadataPath
        $metadataAcl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
        Set-Acl -LiteralPath $metadataPath -AclObject $metadataAcl -ErrorAction Stop
        return [pscustomobject]@{ SchemaVersion = 1; Changed = $true; State = 'Installed'; Detail = 'Local readiness passed. Reboot/no-login and fresh-host acceptance remain separate gates.' }
    } catch {
        $rollbackErrors = @()
        $registeredArray = @($registered.ToArray())
        [Array]::Reverse($registeredArray)
        foreach ($service in $registeredArray) {
            try {
                $existing = Get-Service -Name $service.Name -ErrorAction SilentlyContinue
                $attemptInventory = [pscustomobject]@{ InstallRoot = $Config.InstallRoot; DataRoot = $Config.DataRoot; Services = @($service); Components = $Manifest.components }
                Assert-MonitorOwnedServices -Config $Config -Installation $attemptInventory -AllowMissing
                if ($existing -and $existing.Status -ne 'Stopped') { Invoke-MonitorNative -Path $service.WrapperPath -Arguments @('stop') -FailureMessage 'Rollback service stop failed.' }
                if ($existing) { Invoke-MonitorNative -Path $service.WrapperPath -Arguments @('uninstall') -FailureMessage 'Rollback service removal failed.' }
            } catch { $rollbackErrors += $service.Name }
        }
        $rollbackState = if ($rollbackErrors.Count -eq 0) { 'Created service registrations were removed.' } else { 'Some created service registrations could not be removed; operator recovery is required.' }
        throw ('Installation failed during ' + $phase + '. ' + $rollbackState + ' Dedicated directories and any history remain preserved; inspect protected local component logs before recovery.')
    }
}

function Invoke-MonitorServiceOperation {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Start', 'Stop', 'Uninstall')][string]$Operation,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory = $true)]$Installation
    )
    Assert-MonitorOwnedServices -Config $Config -Installation $Installation -AllowMissing:($Operation -eq 'Uninstall')
    if (-not $PSCmdlet.ShouldProcess(($Installation.Services.Name -join ', '), ($Operation + ' owned monitoring services'))) { return }
    Assert-MonitorAdministrator
    $services = @($Installation.Services)
    if ($Operation -ne 'Start') { [Array]::Reverse($services) }
    foreach ($service in $services) {
        $existing = Get-Service -Name $service.Name -ErrorAction SilentlyContinue
        if (-not $existing -and $Operation -eq 'Uninstall') { continue }
        if ($Operation -eq 'Start' -and $existing.Status -eq 'Running') { continue }
        if ($Operation -ne 'Start' -and $existing.Status -ne 'Stopped') {
            Invoke-MonitorNative -Path $service.WrapperPath -Arguments @('stop') -FailureMessage ('Service stop failed: ' + $service.Name)
            (Get-Service -Name $service.Name).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(75))
        }
        if ($Operation -eq 'Start') {
            Invoke-MonitorNative -Path $service.WrapperPath -Arguments @('start') -FailureMessage ('Service start failed: ' + $service.Name)
            (Get-Service -Name $service.Name).WaitForStatus('Running', [TimeSpan]::FromSeconds(40))
        }
        if ($Operation -eq 'Uninstall') { Invoke-MonitorNative -Path $service.WrapperPath -Arguments @('uninstall') -FailureMessage ('Service removal failed: ' + $service.Name) }
    }
    if ($Operation -eq 'Start') { Wait-MonitorReadiness -Config $Config }
}

function Invoke-MonitorUninstall {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory = $true)]$Installation,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [switch]$RemoveBinaries,
        [switch]$PurgeData
    )
    Assert-MonitorOwnedServices -Config $Config -Installation $Installation -AllowMissing
    Assert-MonitorSafeDirectory -Path $Config.InstallRoot -RepositoryRoot $RepositoryRoot
    Assert-MonitorSafeDirectory -Path $Config.DataRoot -RepositoryRoot $RepositoryRoot
    if ($RemoveBinaries) { Assert-MonitorNoReparsePoint -Path $Config.InstallRoot -Recurse }
    if ($PurgeData) { Assert-MonitorNoReparsePoint -Path $Config.DataRoot -Recurse }
    if (-not $PSCmdlet.ShouldProcess(($Installation.Services.Name -join ', '), 'Remove owned monitoring service registrations; preserve data unless explicitly requested')) { return }
    Assert-MonitorAdministrator
    Invoke-MonitorServiceOperation -Operation Uninstall -Config $Config -Installation $Installation -Confirm:$false
    $Installation.State = 'Uninstalled'
    [IO.File]::WriteAllText((Join-Path $Config.DataRoot 'installation.json'), ($Installation | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
    if ($RemoveBinaries -and $PSCmdlet.ShouldProcess($Config.InstallRoot, 'Permanently remove the verified owned binary directory')) {
        Remove-Item -LiteralPath ([IO.Path]::GetFullPath($Config.InstallRoot)) -Recurse -Force -ErrorAction Stop
    }
    if ($PurgeData -and $PSCmdlet.ShouldProcess($Config.DataRoot, 'Permanently delete all owned monitoring history, configuration and secrets')) {
        Remove-Item -LiteralPath ([IO.Path]::GetFullPath($Config.DataRoot)) -Recurse -Force -ErrorAction Stop
    }
}

function Get-MonitorBackupPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory = $true)]$Installation,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )
    Assert-MonitorOwnedServices -Config $Config -Installation $Installation
    Assert-MonitorSafeDirectory -Path $DestinationPath
    $destination = [IO.Path]::GetFullPath($DestinationPath).TrimEnd('\', '/')
    foreach ($root in @($Config.InstallRoot, $Config.DataRoot)) {
        $resolvedRoot = [IO.Path]::GetFullPath($root).TrimEnd('\', '/')
        if ($destination -ieq $resolvedRoot -or $destination.StartsWith($resolvedRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or $resolvedRoot.StartsWith($destination + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Backup destination must not overlap the installation or data directory.' }
    }
    if ((Test-Path -LiteralPath $destination) -and @(Get-ChildItem -LiteralPath $destination -Force).Count -gt 0) { throw 'Backup destination must be a new or empty dedicated directory.' }
    return [pscustomobject]@{
        SchemaVersion = 1; Mode = 'PlanOnly'; Operation = 'Backup'; DestinationPath = $destination
        ServicesToStop = @($Installation.Services.Name); Includes = @('config', 'data', 'installation.json')
        Excludes = @('secrets', 'logs', 'binaries'); RequiresServiceInterruption = $true
        Note = 'Historical telemetry is sensitive. Destination receives Administrator/SYSTEM-only permissions. Existing service running states are restored in finally.'
    }
}

function Invoke-MonitorBackup {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory = $true)]$Installation,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )
    $plan = Get-MonitorBackupPlan -Config $Config -Installation $Installation -DestinationPath $DestinationPath
    if (-not $PSCmdlet.ShouldProcess($plan.DestinationPath, 'Stop owned services, copy consistent monitoring state without secrets, then restore prior service states')) { return $plan }
    Assert-MonitorAdministrator
    Assert-MonitorNoReparsePoint -Path $Config.DataRoot -Recurse
    $runningBefore = @($Installation.Services | Where-Object { (Get-Service -Name $_.Name).Status -eq 'Running' })
    $null = [IO.Directory]::CreateDirectory($plan.DestinationPath)
    Set-MonitorBackupAcl -Path $plan.DestinationPath
    try {
        Invoke-MonitorServiceOperation -Operation Stop -Config $Config -Installation $Installation -Confirm:$false
        foreach ($relative in @('config', 'data', 'installation.json')) {
            $source = Join-Path $Config.DataRoot $relative
            if (-not (Test-Path -LiteralPath $source)) { throw 'A required backup source is missing.' }
            Copy-Item -LiteralPath $source -Destination (Join-Path $plan.DestinationPath $relative) -Recurse -ErrorAction Stop
        }
        $inventory = @()
        foreach ($file in Get-ChildItem -LiteralPath $plan.DestinationPath -Recurse -File -Force) {
            $relative = $file.FullName.Substring($plan.DestinationPath.Length).TrimStart('\', '/')
            $inventory += [pscustomobject]@{ RelativePath = $relative; Length = $file.Length; Sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
        }
        $backupManifest = [ordered]@{
            SchemaVersion = 1; State = 'Complete'; TimestampUtc = [DateTime]::UtcNow.ToString('o')
            Components = $Installation.Components; Config = $Installation.Config
            SecretFilesIncluded = $false; Files = $inventory
        }
        [IO.File]::WriteAllText((Join-Path $plan.DestinationPath 'backup-manifest.json'), ($backupManifest | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
    } finally {
        Restore-MonitorRunningStates -Services $runningBefore
    }
    return [pscustomobject]@{ SchemaVersion = 1; Mode = 'Applied'; Operation = 'Backup'; DestinationPath = $plan.DestinationPath; FileCount = $inventory.Count; SecretFilesIncluded = $false }
}

function Get-MonitorRestorePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory = $true)]$Installation,
        [Parameter(Mandatory = $true)][string]$BackupPath
    )
    Assert-MonitorOwnedServices -Config $Config -Installation $Installation
    Assert-MonitorSafeDirectory -Path $BackupPath
    Assert-MonitorNoReparsePoint -Path $BackupPath -Recurse
    $backupRoot = [IO.Path]::GetFullPath($BackupPath).TrimEnd('\', '/')
    $manifestPath = Join-Path $backupRoot 'backup-manifest.json'
    try { $backup = Get-Content -Raw -LiteralPath $manifestPath -Encoding UTF8 | ConvertFrom-Json } catch { throw 'A complete backup manifest is required before restore.' }
    if ($backup.SchemaVersion -ne 1 -or $backup.State -ne 'Complete' -or $backup.SecretFilesIncluded -ne $false -or @($backup.Files).Count -eq 0) { throw 'Unsupported or incomplete backup manifest.' }
    Assert-MonitorMatchingInstallation -Config $Config -Manifest ([pscustomobject]@{ components = $backup.Components }) -Installation $Installation
    foreach ($key in $Config.Keys) {
        if ($null -eq $backup.Config.PSObject.Properties[$key] -or [string]$backup.Config.$key -cne [string]$Config[$key]) { throw 'Backup roots/configuration must match the destination installation; cross-path or cross-version migration is not supported.' }
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $bytes = [long]0
    foreach ($file in $backup.Files) {
        $relative = [string]$file.RelativePath
        if (-not $relative -or [IO.Path]::IsPathRooted($relative) -or $relative -match '[:\x00-\x1f]' -or ($relative -split '[\\/]') -contains '..' -or $relative -notmatch '^(config[\\/]|data[\\/]|installation\.json$)' -or -not $seen.Add($relative)) { throw 'Unsafe or duplicate file entry in backup manifest.' }
        $source = [IO.Path]::GetFullPath((Join-Path $backupRoot $relative))
        if (-not $source.StartsWith($backupRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Backup member escapes its root.' }
        Assert-MonitorArtifactHash -Path $source -ExpectedSha256 $file.Sha256
        $length = (Get-Item -LiteralPath $source).Length
        if ($file.Length -ne $length) { throw 'Backup member size does not match its manifest.' }
        $bytes += $length
    }
    foreach ($required in @('installation.json', 'config', 'data')) {
        if (-not (Test-Path -LiteralPath (Join-Path $backupRoot $required))) { throw 'Backup is missing required configuration, history or ownership metadata.' }
    }
    $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($Config.DataRoot))
    if ($drive.AvailableFreeSpace -lt ($bytes + 100MB)) { throw 'Insufficient free space to stage the backup without overwriting existing history.' }
    return [pscustomobject]@{
        SchemaVersion = 1; Mode = 'PlanOnly'; Operation = 'Restore'; BackupPath = $backupRoot
        DestinationPath = $Config.DataRoot; FileCount = @($backup.Files).Count; StagingBytes = $bytes
        SecretFilesIncluded = $false; BackupManifest = $backup
        Note = 'Restore requires identical component versions and configuration. Existing secrets remain unchanged. Old data/configuration are retained in a rollback directory.'
    }
}

function Invoke-MonitorRestore {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory = $true)]$Installation,
        [Parameter(Mandatory = $true)][string]$BackupPath
    )
    $plan = Get-MonitorRestorePlan -Config $Config -Installation $Installation -BackupPath $BackupPath
    if (-not $PSCmdlet.ShouldProcess($Config.DataRoot, 'Stop owned services and restore verified same-version backup; preserve original directories for rollback')) { return $plan }
    Assert-MonitorAdministrator
    Assert-MonitorNoReparsePoint -Path $Config.DataRoot -Recurse
    $transactionId = [Guid]::NewGuid().ToString('N')
    $stagePath = Join-Path $Config.DataRoot ('restore-stage-' + $transactionId)
    $rollbackPath = Join-Path $Config.DataRoot ('restore-previous-' + $transactionId)
    $null = [IO.Directory]::CreateDirectory($stagePath)
    $null = [IO.Directory]::CreateDirectory($rollbackPath)
    Set-MonitorDirectoryAcl -Path $stagePath
    Set-MonitorBackupAcl -Path $rollbackPath
    foreach ($relative in @('config', 'data', 'data/prometheus', 'data/grafana')) {
        $path = Join-Path $stagePath $relative
        $null = [IO.Directory]::CreateDirectory($path)
        if ($relative -like 'data/*') { Set-MonitorDirectoryAcl -Path $path -LocalServiceRights Modify }
    }
    foreach ($file in $plan.BackupManifest.Files) {
        if ($file.RelativePath -eq 'installation.json') { continue }
        $source = Join-Path $plan.BackupPath $file.RelativePath
        $destination = Join-Path $stagePath $file.RelativePath
        $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
        Copy-Item -LiteralPath $source -Destination $destination -ErrorAction Stop
        Assert-MonitorArtifactHash -Path $destination -ExpectedSha256 $file.Sha256
    }
    $runningBefore = @($Installation.Services | Where-Object { (Get-Service -Name $_.Name).Status -eq 'Running' })
    $oldMoved = New-Object 'System.Collections.Generic.List[string]'
    $newMoved = New-Object 'System.Collections.Generic.List[string]'
    try {
        Invoke-MonitorServiceOperation -Operation Stop -Config $Config -Installation $Installation -Confirm:$false
        foreach ($relative in @('config', 'data')) {
            $current = Join-Path $Config.DataRoot $relative
            Move-Item -LiteralPath $current -Destination (Join-Path $rollbackPath $relative) -ErrorAction Stop
            $oldMoved.Add($relative)
            Move-Item -LiteralPath (Join-Path $stagePath $relative) -Destination $current -ErrorAction Stop
            $newMoved.Add($relative)
        }
        Restore-MonitorRunningStates -Services $runningBefore
        if ($runningBefore.Count -eq 3) { Wait-MonitorReadiness -Config $Config }
    } catch {
        $rollbackSucceeded = $true
        try {
            Invoke-MonitorServiceOperation -Operation Stop -Config $Config -Installation $Installation -Confirm:$false
            foreach ($relative in $newMoved) { Move-Item -LiteralPath (Join-Path $Config.DataRoot $relative) -Destination (Join-Path $stagePath $relative) -ErrorAction Stop }
            foreach ($relative in $oldMoved) { Move-Item -LiteralPath (Join-Path $rollbackPath $relative) -Destination (Join-Path $Config.DataRoot $relative) -ErrorAction Stop }
            Restore-MonitorRunningStates -Services $runningBefore
        } catch { $rollbackSucceeded = $false }
        if ($rollbackSucceeded) { throw 'Restore failed; original directories and service states were restored. Staging and backup were preserved.' }
        throw 'Restore failed and rollback could not be fully verified. Preserve all staging/previous directories and perform operator recovery before starting services.'
    }
    return [pscustomobject]@{ SchemaVersion = 1; Mode = 'Applied'; Operation = 'Restore'; PreviousStatePath = $rollbackPath; SecretFilesChanged = $false }
}

function Restore-MonitorRunningStates {
    param([object[]]$Services)
    foreach ($service in $Services) {
        $current = Get-Service -Name $service.Name -ErrorAction Stop
        if ($current.Status -eq 'Running') { continue }
        Invoke-MonitorNative -Path $service.WrapperPath -Arguments @('start') -FailureMessage ('Service-state recovery failed: ' + $service.Name)
        (Get-Service -Name $service.Name).WaitForStatus('Running', [TimeSpan]::FromSeconds(40))
    }
}

function Set-MonitorBackupAcl {
    param([string]$Path)
    Assert-MonitorNoReparsePoint -Path $Path
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sidValue in @('S-1-5-18', 'S-1-5-32-544')) {
        $sid = New-Object Security.Principal.SecurityIdentifier($sidValue)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Assert-MonitorSafeDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [string]$RepositoryRoot)
    if ($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path -match '[%\x00-\x1f]') { throw 'A literal fully qualified local directory is required.' }
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if ($fullPath -eq [IO.Path]::GetPathRoot($fullPath).TrimEnd('\', '/')) { throw 'Drive roots are not dedicated installation directories.' }
    if ($RepositoryRoot) {
        $repositoryPath = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\', '/')
        if ($fullPath -ieq $repositoryPath -or $fullPath.StartsWith($repositoryPath + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Installed binary/data roots cannot be inside the source repository.' }
    }
    $windowsPath = [Environment]::GetFolderPath('Windows').TrimEnd('\')
    if ($fullPath -ieq $windowsPath -or $fullPath.StartsWith($windowsPath + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Windows system directories cannot be used as owned roots.' }
    Assert-MonitorNoReparsePoint -Path $fullPath
    return
}

function Assert-MonitorAdministrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'ADMIN_REQUIRED: Open an Administrator PowerShell session after approving the installation plan.' }
}

function Assert-MonitorNoReparsePoint {
    param([string]$Path, [switch]$Recurse)
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Owned paths cannot contain reparse points.' }
        $parent = Split-Path -Parent $cursor
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
    if ($Recurse -and (Test-Path -LiteralPath $Path)) {
        foreach ($item in Get-ChildItem -LiteralPath $Path -Recurse -Force) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Owned directory tree contains a reparse point.' }
        }
    }
}

function Assert-MonitorMatchingInstallation {
    param([System.Collections.IDictionary]$Config, $Manifest, $Installation)
    foreach ($component in $Manifest.components) {
        $installed = @($Installation.Components | Where-Object id -eq $component.id)
        if ($installed.Count -ne 1 -or $installed[0].version -cne $component.version -or $installed[0].sha256 -ine $component.sha256) { throw 'Automatic version upgrades are not supported yet. Preserve a verified compatible backup and use a reviewed migration plan.' }
    }
    foreach ($key in $Config.Keys) {
        if ($null -eq $Installation.Config.PSObject.Properties[$key] -or [string]$Installation.Config.$key -cne [string]$Config[$key]) { throw 'Changing effective configuration on an existing installation requires a reviewed migration; the existing installation was preserved.' }
    }
}

function Set-MonitorDirectoryAcl {
    param([string]$Path, [ValidateSet('ReadAndExecute', 'Modify')][string]$LocalServiceRights = 'ReadAndExecute')
    Assert-MonitorNoReparsePoint -Path $Path
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($entry in @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'), @('S-1-5-19', $LocalServiceRights))) {
        $sid = New-Object Security.Principal.SecurityIdentifier($entry[0])
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, $entry[1], 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Invoke-MonitorBinaryPreflight {
    param([string]$Path, [string]$ComponentId)
    Invoke-MonitorNative -Path $Path -Arguments @('--version') -FailureMessage ($ComponentId + ' executable preflight failed or was blocked by Windows Application Control. No service has been installed; resolve the host policy through an approved administrator process before retrying.')
}

function Invoke-MonitorNative {
    param([string]$Path, [string[]]$Arguments, [string]$FailureMessage)
    $process = New-Object Diagnostics.Process
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Path
    $start.Arguments = (@($Arguments | ForEach-Object { ConvertTo-MonitorNativeArgument -Value $_ }) -join ' ')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = Split-Path -Parent $Path
    $process.StartInfo = $start
    try {
        # Exporter stdout may contain sensitive Windows service arguments; never log it.
        $null = $process.Start()
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) { $process.Kill(); throw $FailureMessage }
        $null = $outputTask.GetAwaiter().GetResult()
        $null = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw $FailureMessage }
    } catch { throw $FailureMessage } finally { $process.Dispose() }
}

function ConvertTo-MonitorNativeArgument {
    param([string]$Value)
    if ($Value -and $Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object Text.StringBuilder
    $null = $builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            $null = $builder.Append(('\' * ($slashes * 2 + 1))).Append('"')
        } else {
            $null = $builder.Append(('\' * $slashes)).Append($character)
        }
        $slashes = 0
    }
    $null = $builder.Append(('\' * ($slashes * 2))).Append('"')
    return $builder.ToString()
}

function Assert-MonitorProtectedMetadata {
    param([string]$Path)
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -notin @('S-1-5-18', 'S-1-5-32-544')) { throw 'Installation metadata must be owned by Administrators or SYSTEM.' }
    $writeRights = [Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne 'Allow' -or $rule.IdentityReference.Value -in @('S-1-5-18', 'S-1-5-32-544')) { continue }
        if (($rule.FileSystemRights -band $writeRights) -ne 0) { throw 'Installation metadata is writable by an untrusted identity.' }
    }
}

function Write-MonitorServiceXml {
    param($Service, [System.Collections.IDictionary]$Config)
    $arguments = switch ($Service.Component) {
        'windows_exporter' { '--config.file="' + (Join-Path $Config.DataRoot 'config/exporters/windows_exporter.yml') + '"' }
        'prometheus' {
            '--config.file="' + (Join-Path $Config.DataRoot 'config/prometheus/prometheus.yml') + '" --storage.tsdb.path="' + (Join-Path $Config.DataRoot 'data/prometheus') + '" --storage.tsdb.retention.time=' + $Config.RetentionTime + ' --storage.tsdb.retention.size=' + $Config.RetentionSize + ' --web.listen-address=127.0.0.1:' + $Config.PrometheusPort
        }
        'grafana' { 'server --homepath="' + (Split-Path (Split-Path $Service.ExecutablePath -Parent) -Parent) + '" --config="' + (Join-Path $Config.DataRoot 'config/grafana/grafana.ini') + '"' }
    }
    $workingDirectory = if ($Service.Component -eq 'grafana') { Split-Path (Split-Path $Service.ExecutablePath -Parent) -Parent } else { Split-Path -Parent $Service.ExecutablePath }
    $document = New-Object Xml.XmlDocument
    $root = $document.CreateElement('service')
    $null = $document.AppendChild($root)
    $properties = [ordered]@{
        id = $Service.Name; name = $Service.Name; description = 'PC Monitor localhost monitoring component'
        executable = $Service.ExecutablePath; arguments = $arguments; workingdirectory = $workingDirectory
        startmode = 'Automatic'; stoptimeout = '60 sec'; stopparentprocessfirst = 'true'
        logpath = (Join-Path (Join-Path $Config.DataRoot 'logs') $Service.Component)
    }
    foreach ($key in $properties.Keys) {
        $element = $document.CreateElement($key); $element.InnerText = [string]$properties[$key]
        $null = $root.AppendChild($element)
    }
    $account = $document.CreateElement('serviceaccount')
    if ($Service.Account -ne 'LocalSystem') {
        $domain = $document.CreateElement('domain'); $domain.InnerText = 'NT AUTHORITY'; $null = $account.AppendChild($domain)
    }
    $user = $document.CreateElement('user'); $user.InnerText = if ($Service.Account -eq 'LocalSystem') { 'LocalSystem' } else { 'LocalService' }; $null = $account.AppendChild($user)
    $null = $root.AppendChild($account)
    foreach ($delay in @('10 sec', '30 sec')) {
        $failure = $document.CreateElement('onfailure'); $failure.SetAttribute('action', 'restart'); $failure.SetAttribute('delay', $delay); $null = $root.AppendChild($failure)
    }
    $log = $document.CreateElement('log'); $log.SetAttribute('mode', 'roll-by-size')
    foreach ($entry in @(@('sizeThreshold', '10240'), @('keepFiles', '8'))) {
        $element = $document.CreateElement($entry[0]); $element.InnerText = $entry[1]; $null = $log.AppendChild($element)
    }
    $null = $root.AppendChild($log)
    $settings = New-Object Xml.XmlWriterSettings
    $settings.Indent = $true; $settings.Encoding = New-Object Text.UTF8Encoding($false)
    $writer = [Xml.XmlWriter]::Create([IO.Path]::ChangeExtension($Service.WrapperPath, '.xml'), $settings)
    try { $document.Save($writer) } finally { $writer.Dispose() }
}

function Wait-MonitorReadiness {
    param([System.Collections.IDictionary]$Config)
    $endpoints = @(
        ('http://127.0.0.1:' + $Config.ExporterPort + '/metrics'),
        ('http://127.0.0.1:' + $Config.PrometheusPort + '/-/ready'),
        ('http://127.0.0.1:' + $Config.GrafanaPort + '/api/health')
    )
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    do {
        $ready = $true
        foreach ($endpoint in $endpoints) {
            try {
                $response = Invoke-WebRequest -Uri $endpoint -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
                if ($response.StatusCode -ne 200) { $ready = $false }
            } catch { $ready = $false }
        }
        if ($ready) {
            try {
                $query = [Uri]::EscapeDataString('up{job="windows_exporter"}')
                $scrape = Invoke-RestMethod -Uri ('http://127.0.0.1:' + $Config.PrometheusPort + '/api/v1/query?query=' + $query) -TimeoutSec 3 -ErrorAction Stop
                if ($scrape.status -eq 'success' -and @($scrape.data.result | Where-Object { $_.value[1] -eq '1' }).Count -gt 0) { return }
            } catch { }
        }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Local readiness failed: verify exporter collectors, Prometheus scrape and Grafana health using protected local logs.'
}

Export-ModuleMember -Function Get-MonitorInstallPlan, Get-MonitorInstallation, Assert-MonitorOwnedServices, Invoke-MonitorInstall, Invoke-MonitorServiceOperation, Invoke-MonitorUninstall, Get-MonitorBackupPlan, Invoke-MonitorBackup, Get-MonitorRestorePlan, Invoke-MonitorRestore, Assert-MonitorSafeDirectory
