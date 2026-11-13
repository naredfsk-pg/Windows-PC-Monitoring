[CmdletBinding()]
param([string]$RepositoryRoot)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if (-not $RepositoryRoot) { $RepositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) }
. (Join-Path $RepositoryRoot 'tests/TestSupport.ps1')

function Invoke-RendererChecks {
    param([string]$Root)
    Import-Module (Join-Path $Root 'scripts/lib/Config.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/lib/Secrets.psm1') -Force
    $results = New-Object System.Collections.Generic.List[object]
    $testRoot = New-QATemporaryDirectory
    try {
        $fixtureRoot = Join-Path $testRoot 'repository'
        [IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
        Copy-Item -LiteralPath (Join-Path $Root 'config') -Destination (Join-Path $fixtureRoot 'config') -Recurse
        $config = Get-MonitorDefaults
        $config.InstallRoot = Join-Path $testRoot 'install'
        $config.DataRoot = Join-Path $testRoot 'data'
        Invoke-QACase $results 'Rendered assets preserve Grafana legends and use a password-file reference' {
            $outputPath = Join-Path $testRoot 'rendered'
            $paths = @(Write-MonitorConfiguration -Config $config -OutputPath $outputPath -RepositoryRoot $fixtureRoot)
            Assert-QATrue ($paths.Count -ge 8) 'Core rendering did not produce the expected asset families.'
            $ini = [IO.File]::ReadAllText((Join-Path $outputPath 'grafana/grafana.ini'))
            Assert-QATrue ($ini -match '(?m)^http_addr = 127\.0\.0\.1$') 'Grafana did not bind loopback.'
            Assert-QATrue ($ini -match '(?m)^admin_password = \$__file\{.+grafana-admin-password\}$') 'Grafana lacks the protected file-provider password reference.'
            Assert-QATrue ($ini -match '(?m)^cookie_secure = false$') 'Local HTTP configuration enabled secure-only cookies.'
            $processes = [IO.File]::ReadAllText((Join-Path $outputPath 'grafana/dashboards/processes.json'))
            Assert-QATrue ($processes.Contains('{{process}}') -and $processes.Contains('{{process_id}}')) 'Legitimate Grafana legends were lost.'
            $null = $processes | ConvertFrom-Json
        }
        Invoke-QACase $results 'WhatIf rendering creates no output directory' {
            $outputPath = Join-Path $testRoot 'whatif'
            Write-MonitorConfiguration -Config $config -OutputPath $outputPath -RepositoryRoot $fixtureRoot -WhatIf
            Assert-QATrue (-not (Test-Path -LiteralPath $outputPath)) 'Renderer WhatIf wrote output.'
        }
        Invoke-QACase $results 'Owner rendering enables secure cookies and the configured public URL' {
            $ownerConfig = $config.Clone()
            $ownerConfig.Profile = 'owner'
            $ownerConfig.PublicHostname = 'monitor.example.com'
            $ownerConfig.GrafanaUrl = 'https://monitor.example.com'
            $outputPath = Join-Path $testRoot 'owner'
            Write-MonitorConfiguration -Config $ownerConfig -OutputPath $outputPath -RepositoryRoot $fixtureRoot | Out-Null
            $ini = [IO.File]::ReadAllText((Join-Path $outputPath 'grafana/grafana.ini'))
            Assert-QATrue ($ini -match '(?m)^cookie_secure = true$') 'Owner HTTPS configuration did not enable secure cookies.'
            Assert-QATrue ($ini -match '(?m)^root_url = https://monitor\.example\.com$') 'Owner root URL was not rendered.'
        }
        foreach ($token in @('{{UNKNOWN}}', '{{TOKEN1}}', '{{lowercase}}', '{{Process}}')) {
            Invoke-QACase $results ('Unknown template token is rejected before writes: ' + $token) {
                $sourcePath = Join-Path $fixtureRoot 'config/prometheus.yml.tpl'
                $originalText = [IO.File]::ReadAllText($sourcePath)
                $outputPath = Join-Path $testRoot ('unknown-' + [Guid]::NewGuid().ToString('N'))
                try {
                    [IO.File]::WriteAllText($sourcePath, ($originalText + "`n# " + $token))
                    Assert-QAThrows { Write-MonitorConfiguration -Config $config -OutputPath $outputPath -RepositoryRoot $fixtureRoot } 'Unknown placeholder was silently accepted.'
                    Assert-QATrue (-not (Test-Path -LiteralPath $outputPath)) 'Renderer wrote partial output before rejecting a token.'
                } finally { [IO.File]::WriteAllText($sourcePath, $originalText) }
            }
        }
        Invoke-QACase $results 'YAML process scalar quoting preserves apostrophes' {
            $quotedConfig = $config.Clone()
            $quotedConfig.ProcessInclude = "example'app"
            $outputPath = Join-Path $testRoot 'quoted'
            Write-MonitorConfiguration -Config $quotedConfig -OutputPath $outputPath -RepositoryRoot $fixtureRoot | Out-Null
            $yaml = [IO.File]::ReadAllText((Join-Path $outputPath 'exporters/windows_exporter.yml'))
            Assert-QATrue ($yaml.Contains("'example''app'")) 'Process regex was not YAML-quoted safely.'
        }
        Invoke-QACase $results 'Inherited or unexpected secret ACLs prevent reading synthetic plaintext' {
            $insecureRoot = Join-Path $testRoot 'insecure-store'
            $secretPath = Get-MonitorSecretPath -Name GrafanaAdminPassword -DataRoot $insecureRoot
            [IO.Directory]::CreateDirectory((Split-Path -Parent $secretPath)) | Out-Null
            [IO.File]::WriteAllText($secretPath, 'synthetic-test-password')
            Assert-QAThrows { Get-MonitorSecret -Name GrafanaAdminPassword -DataRoot $insecureRoot } 'Secret reader accepted an unprotected store.'
            $directory = Split-Path -Parent $secretPath
            $acl = Get-Acl -LiteralPath $directory
            $acl.SetAccessRuleProtection($true, $true)
            Set-Acl -LiteralPath $directory -AclObject $acl
            Assert-QAThrows { Get-MonitorSecret -Name GrafanaAdminPassword -DataRoot $insecureRoot } 'Secret reader accepted unexpected explicit user permissions.'
        }
        Invoke-JunctionChecks -Results $results -TestRoot $testRoot -FixtureRoot $fixtureRoot -Config $config
    } finally { Remove-QATemporaryDirectory -Path $testRoot }
    Complete-QACases -Results $results -Suite 'Renderer and secret safety regression'
}

function Invoke-JunctionChecks {
    param([System.Collections.Generic.List[object]]$Results, [string]$TestRoot, [string]$FixtureRoot, [System.Collections.IDictionary]$Config)
    $targetPath = Join-Path $TestRoot 'junction-target'
    $linkPath = Join-Path $TestRoot 'junction-output'
    [IO.Directory]::CreateDirectory($targetPath) | Out-Null
    try { New-Item -ItemType Junction -Path $linkPath -Target $targetPath -ErrorAction Stop | Out-Null }
    catch {
        $Results.Add([pscustomobject]@{ Status = 'SKIPPED'; Name = 'Renderer junction confinement'; Detail = ' - Junction creation unavailable; runtime confinement gate remains unverified.' })
        return
    }
    Invoke-QACase $Results 'Output junction redirection is rejected before writing its target' {
        Assert-QAThrows { Write-MonitorConfiguration -Config $Config -OutputPath $linkPath -RepositoryRoot $FixtureRoot } 'Renderer followed an output junction.'
        Assert-QATrue (@(Get-ChildItem -LiteralPath $targetPath -Force).Count -eq 0) 'Renderer wrote through an output junction.'
        Assert-QAThrows { Write-MonitorConfiguration -Config $Config -OutputPath (Join-Path $linkPath 'nested') -RepositoryRoot $FixtureRoot } 'Renderer followed an output ancestor junction.'
    }
    Invoke-QACase $Results 'Existing nested output junction is rejected' {
        $outputRoot = Join-Path $TestRoot 'nested-junction-output'
        [IO.Directory]::CreateDirectory($outputRoot) | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $outputRoot 'grafana') -Target $targetPath -ErrorAction Stop | Out-Null
        Assert-QAThrows { Write-MonitorConfiguration -Config $Config -OutputPath $outputRoot -RepositoryRoot $FixtureRoot } 'Renderer followed a nested destination junction.'
        Assert-QATrue (@(Get-ChildItem -LiteralPath $targetPath -Force).Count -eq 0) 'Renderer wrote through a nested destination junction.'
    }
    Invoke-QACase $Results 'Source junction is rejected' {
        $sourcePath = Join-Path $FixtureRoot 'config/exporters'
        $movedSource = Join-Path $FixtureRoot 'config/exporters-original'
        Move-Item -LiteralPath $sourcePath -Destination $movedSource
        try {
            New-Item -ItemType Junction -Path $sourcePath -Target $movedSource -ErrorAction Stop | Out-Null
            Assert-QAThrows { Write-MonitorConfiguration -Config $Config -OutputPath (Join-Path $TestRoot 'source-junction-output') -RepositoryRoot $FixtureRoot } 'Renderer followed a source junction.'
        } finally {
            if (Test-Path -LiteralPath $sourcePath) { [IO.Directory]::Delete($sourcePath) }
            Move-Item -LiteralPath $movedSource -Destination $sourcePath
        }
    }
}

Invoke-RendererChecks -Root (Resolve-Path -LiteralPath $RepositoryRoot).Path
