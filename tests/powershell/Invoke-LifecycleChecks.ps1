[CmdletBinding()]
param([string]$RepositoryRoot)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if (-not $RepositoryRoot) { $RepositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) }
. (Join-Path $RepositoryRoot 'tests/TestSupport.ps1')

function Invoke-LifecycleChecks {
    param([string]$Root)
    Import-Module (Join-Path $Root 'scripts/lib/Config.psm1') -Force
    $artifactModule = Import-Module (Join-Path $Root 'scripts/lib/Artifacts.psm1') -Force -PassThru
    $serviceModule = Import-Module (Join-Path $Root 'scripts/lib/Services.psm1') -Force -PassThru
    $results = New-Object System.Collections.Generic.List[object]
    $testRoot = New-QATemporaryDirectory
    try {
        $manifest = Read-MonitorManifest -Path (Join-Path $Root 'config/dependencies.lock.json')
        $config = Get-MonitorDefaults
        $config.InstallRoot = Join-Path $testRoot 'install'
        $config.DataRoot = Join-Path $testRoot 'data'
        Invoke-QACase $results 'Invalid dependency metadata fails before downloading' {
            foreach ($mutation in @('DuplicateId', 'UnsafeUrl', 'UrlCredentials', 'ExecutableTraversal', 'InvalidHash')) {
                $changed = $manifest | ConvertTo-Json -Depth 8 | ConvertFrom-Json
                switch ($mutation) {
                    DuplicateId { $changed.components[0].id = $changed.components[1].id }
                    UnsafeUrl { $changed.components[0].url = 'http://github.com/example/archive.zip' }
                    UrlCredentials { $changed.components[0].url = 'https://user:synthetic@github.com/example/archive.zip' }
                    ExecutableTraversal { $changed.components[0].executableRelativePath = '../escape.exe' }
                    InvalidHash { $changed.components[0].sha256 = 'not-a-hash' }
                }
                $path = Join-Path $testRoot ($mutation + '.json')
                $changed | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
                Assert-QAThrows { Read-MonitorManifest -Path $path } ('Invalid manifest accepted: ' + $mutation)
            }
        }
        Invoke-QACase $results 'Hash mismatch refuses extraction before creating destination' {
            $path = Join-Path $testRoot 'synthetic.exe'
            [IO.File]::WriteAllText($path, 'synthetic harmless payload')
            $component = New-SyntheticComponent -Path $path -ArchiveType exe
            $component.sha256 = 'a' * 64
            $destination = Join-Path $testRoot 'hash-mismatch-destination'
            Assert-QAThrows { Expand-MonitorArtifact -Component $component -ArtifactPath $path -DestinationPath $destination -Confirm:$false } 'Hash mismatch was accepted.'
            Assert-QATrue (-not (Test-Path -LiteralPath $destination)) 'Extraction created output before validating SHA-256.'
        }
        Invoke-QACase $results 'Corrupted cache fails closed without network fallback' {
            $cache = Join-Path $testRoot 'bad-cache'
            [IO.Directory]::CreateDirectory($cache) | Out-Null
            $path = Join-Path $cache 'synthetic.exe'
            [IO.File]::WriteAllText($path, 'synthetic harmless payload')
            $component = New-SyntheticComponent -Path $path -ArchiveType exe
            $component.sha256 = 'a' * 64
            & $artifactModule {
                $script:QANetworkCalls = 0
                function script:Invoke-WebRequest { $script:QANetworkCalls++; throw 'QA forbids network access.' }
            }
            Assert-QAThrows { Get-MonitorArtifact -Component $component -CachePath $cache -Confirm:$false } 'Corrupted cache was accepted.'
            $calls = & $artifactModule { $script:QANetworkCalls }
            Assert-QATrue ($calls -eq 0) 'Corrupted cache triggered a download.'
        }
        Invoke-QACase $results 'Download WhatIf creates no cache or partial file' {
            $path = Join-Path $testRoot 'synthetic.exe'
            $component = New-SyntheticComponent -Path $path -ArchiveType exe
            $cache = Join-Path $testRoot 'whatif-cache'
            Get-MonitorArtifact -Component $component -CachePath $cache -WhatIf
            Assert-QATrue (-not (Test-Path -LiteralPath $cache)) 'Artifact WhatIf created a cache directory.'
        }
        Invoke-QACase $results 'Valid archive is normalized without executing its synthetic payload' {
            $path = Join-Path $testRoot 'valid.zip'
            New-SyntheticZip -Path $path -Member 'bundle/synthetic.exe'
            $component = New-SyntheticComponent -Path $path -ArchiveType zip
            $destination = Join-Path $testRoot 'expanded-valid'
            Expand-MonitorArtifact -Component $component -ArtifactPath $path -DestinationPath $destination -Confirm:$false | Out-Null
            Assert-QATrue ([IO.File]::ReadAllText((Join-Path $destination 'synthetic.exe')) -eq 'synthetic harmless payload') 'Archive root normalization corrupted payload content.'
        }
        foreach ($member in @('bundle/../escape.exe', 'bundle/C:/escape.exe', 'bundle/CON', 'bundle/trailing.')) {
            Invoke-QACase $results ('Unsafe archive member is rejected: ' + $member) {
                $id = [Guid]::NewGuid().ToString('N')
                $path = Join-Path $testRoot ($id + '.zip')
                New-SyntheticZip -Path $path -Member $member
                $component = New-SyntheticComponent -Path $path -ArchiveType zip
                Assert-QAThrows { Expand-MonitorArtifact -Component $component -ArtifactPath $path -DestinationPath (Join-Path $testRoot ('bad-' + $id)) -Confirm:$false } 'Unsafe archive member was accepted.'
                Assert-QATrue (-not (Test-Path -LiteralPath (Join-Path $testRoot 'escape.exe'))) 'Archive traversal escaped the destination.'
            }
        }
        Invoke-QACase $results 'Installer WhatIf has no filesystem or elevation side effects' {
            $cache = Join-Path $testRoot 'install-cache'
            $plan = Invoke-MonitorInstall -Config $config -Manifest $manifest -RepositoryRoot $Root -CachePath $cache -WhatIf
            Assert-QATrue ($plan.Mode -eq 'PlanOnly') 'WhatIf did not return a plan.'
            foreach ($path in @($config.InstallRoot, $config.DataRoot, $cache)) {
                Assert-QATrue (-not (Test-Path -LiteralPath $path)) 'Installer WhatIf created installation/cache paths.'
            }
        }
        Invoke-QACase $results 'Lifecycle path guard rejects drive, source and Windows roots' {
            foreach ($path in @('C:\', $Root, (Join-Path $Root 'nested'), $env:SystemRoot, (Join-Path $env:SystemRoot 'nested'))) {
                Assert-QAThrows { Assert-MonitorSafeDirectory -Path $path -RepositoryRoot $Root } 'Unsafe lifecycle directory was accepted.'
            }
        }
        Invoke-QACase $results 'User-created metadata is refused as installation ownership evidence' {
            [IO.Directory]::CreateDirectory($config.DataRoot) | Out-Null
            $metadataPath = Join-Path $config.DataRoot 'installation.json'
            $installation = New-SyntheticInstallation -Config $config -Manifest $manifest
            $installation | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $metadataPath -Encoding UTF8
            Assert-QAThrows { Get-MonitorInstallation -Config $config } 'Unprotected synthetic metadata established installation ownership.'
        }
        Install-OwnershipBoundaryDouble -Module $serviceModule
        $installation = New-SyntheticInstallation -Config $config -Manifest $manifest
        Invoke-QACase $results 'Backup plans exclude secrets and reject root overlap' {
            $backupPath = Join-Path $testRoot 'backup'
            $plan = Get-MonitorBackupPlan -Config $config -Installation $installation -DestinationPath $backupPath
            Assert-QATrue ($plan.Excludes -contains 'secrets') 'Backup plan includes secret files.'
            Assert-QATrue ($plan.RequiresServiceInterruption) 'Consistent backup does not declare service interruption.'
            Assert-QATrue (-not (Test-Path -LiteralPath $backupPath)) 'Backup planning created a destination.'
            foreach ($path in @($config.DataRoot, (Join-Path $config.DataRoot 'backup'), $testRoot)) {
                Assert-QAThrows { Get-MonitorBackupPlan -Config $config -Installation $installation -DestinationPath $path } 'Overlapping backup destination accepted.'
            }
        }
        Invoke-QACase $results 'Restore plans reject incomplete manifests before touching current data' {
            $backupPath = Join-Path $testRoot 'incomplete-backup'
            [IO.Directory]::CreateDirectory($backupPath) | Out-Null
            @{ SchemaVersion = 1; State = 'Incomplete'; SecretFilesIncluded = $false; Files = @() } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupPath 'backup-manifest.json') -Encoding UTF8
            $sentinel = Join-Path $config.DataRoot 'must-preserve.txt'
            [IO.File]::WriteAllText($sentinel, 'preserved')
            Assert-QAThrows { Get-MonitorRestorePlan -Config $config -Installation $installation -BackupPath $backupPath } 'Incomplete backup was accepted.'
            Assert-QATrue ([IO.File]::ReadAllText($sentinel) -eq 'preserved') 'Restore planning altered current data.'
        }
    } finally {
        Remove-Module -ModuleInfo $serviceModule -Force -ErrorAction SilentlyContinue
        Remove-Module -ModuleInfo $artifactModule -Force -ErrorAction SilentlyContinue
        Remove-QATemporaryDirectory -Path $testRoot
    }
    Complete-QACases -Results $results -Suite 'Lifecycle safe failure regression'
}

function New-SyntheticComponent {
    param([string]$Path, [ValidateSet('exe', 'zip')][string]$ArchiveType)
    return [pscustomobject]@{
        id = 'windows_exporter'; version = '9.9.9'; url = ('https://github.com/example/project/releases/download/v9.9.9/' + [IO.Path]::GetFileName($Path))
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash; archiveType = $ArchiveType
        executableRelativePath = 'synthetic.exe'; license = 'MIT'; serviceStrategy = 'winsw'
    }
}

function New-SyntheticZip {
    param([string]$Path, [string]$Member)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entry = $archive.CreateEntry($Member)
        $writer = New-Object IO.StreamWriter($entry.Open())
        try { $writer.Write('synthetic harmless payload') } finally { $writer.Dispose() }
    } finally { $archive.Dispose() }
}

function New-SyntheticInstallation {
    param([System.Collections.IDictionary]$Config, $Manifest)
    $services = @()
    foreach ($name in @('PCMonitor-Exporter', 'PCMonitor-Prometheus', 'PCMonitor-Grafana')) {
        $services += [pscustomobject]@{ Name = $name; WrapperPath = (Join-Path (Join-Path $Config.InstallRoot 'services') ($name + '.exe')) }
    }
    return [pscustomobject]@{ SchemaVersion = 1; State = 'Installed'; InstallRoot = $Config.InstallRoot; DataRoot = $Config.DataRoot; Config = [pscustomobject]$Config; Components = $Manifest.components; Services = $services }
}

function Install-OwnershipBoundaryDouble {
    param([System.Management.Automation.PSModuleInfo]$Module)
    & $Module { function script:Assert-MonitorOwnedServices { param($Config, $Installation, [switch]$AllowMissing) } }
}

Invoke-LifecycleChecks -Root (Resolve-Path -LiteralPath $RepositoryRoot).Path
