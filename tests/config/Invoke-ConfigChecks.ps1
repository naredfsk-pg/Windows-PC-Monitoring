[CmdletBinding()]
param([string]$RepositoryRoot)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Invoke-ConfigurationChecks {
    param([string]$Root)

    Import-Module (Join-Path $Root 'scripts/lib/Config.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/lib/Secrets.psm1') -Force
    $results = New-Object System.Collections.Generic.List[object]
    $temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char]'\')
    $testRoot = Join-Path $temporaryParent ('PCMonitor-QA-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    try {
        Invoke-Scenario $results 'Default configuration validates without owner settings' {
            $config = Read-MonitorConfig
            Assert-True ($config.Profile -eq 'local') 'Default profile is not local.'
            Assert-True ($config.PublicHostname -eq '') 'Default config requires a public hostname.'
            Assert-True ($config.GrafanaUrl -eq 'http://localhost:3000') 'Default Grafana URL is not local.'
            Assert-True ((Test-MonitorConfig -Config $config).Valid) 'Default config is invalid.'
        }
        Invoke-Scenario $results 'Documented local example validates' {
            $config = Read-MonitorConfig -Path (Join-Path $Root 'config/local.example.psd1')
            Assert-True ($config.Profile -eq 'local') 'Example changes deployment profile.'
        }
        Invoke-Scenario $results 'Unknown fields are rejected without echoing the value' {
            $config = Get-MonitorDefaults
            $sensitiveValue = 'synthetic-private-value-' + [Guid]::NewGuid().ToString('N')
            $config.UnrecognizedSetting = $sensitiveValue
            $result = Test-MonitorConfig -Config $config
            Assert-True (-not $result.Valid) 'Unknown field was accepted.'
            Assert-True (($result.Errors -join ' ') -notlike ('*' + $sensitiveValue + '*')) 'Validation reflected sensitive input.'
        }
        Invoke-Scenario $results 'Missing and null configuration fields are rejected' {
            Assert-True (-not (Test-MonitorConfig -Config @{}).Valid) 'Empty configuration accepted.'
            $config = Get-MonitorDefaults
            $config.Profile = $null
            Assert-True (-not (Test-MonitorConfig -Config $config).Valid) 'Null profile accepted.'
        }
        Invoke-Scenario $results 'Unsupported profile is rejected' {
            $config = Get-MonitorDefaults
            $config.Profile = 'public'
            Assert-True (-not (Test-MonitorConfig -Config $config).Valid) 'Unsupported profile accepted.'
        }
        foreach ($invalidPort in @($null, 0, 1023, 65536, -1, '3000', 3000.5, $true)) {
            Invoke-Scenario $results ('Noninteger or out-of-range port rejected: ' + [string]$invalidPort) {
                $config = Get-MonitorDefaults
                $config.GrafanaPort = $invalidPort
                Assert-True (-not (Test-MonitorConfig -Config $config).Valid) 'Invalid port accepted.'
            }
        }
        Invoke-Scenario $results 'Port lower and upper bounds are valid when URL agrees' {
            foreach ($port in @(1024, 65535)) {
                $config = Get-MonitorDefaults
                $config.GrafanaPort = $port
                $config.GrafanaUrl = 'http://localhost:' + $port
                Assert-True ((Test-MonitorConfig -Config $config).Valid) 'Valid boundary port rejected.'
            }
        }
        Invoke-Scenario $results 'Port collisions are rejected' {
            $config = Get-MonitorDefaults
            $config.ExporterPort = $config.PrometheusPort
            Assert-True (-not (Test-MonitorConfig -Config $config).Valid) 'Duplicate service ports accepted.'
        }
        Invoke-Scenario $results 'Durations and retention sizes reject malformed or zero values' {
            foreach ($entry in @(@('ScrapeInterval', '0s'), @('ScrapeInterval', '15 seconds'), @('RetentionTime', '0d'), @('RetentionTime', '30'), @('RetentionSize', '0GB'), @('RetentionSize', '10'))) {
                $config = Get-MonitorDefaults
                $config[$entry[0]] = $entry[1]
                Assert-True (-not (Test-MonitorConfig -Config $config).Valid) 'Malformed duration or size accepted.'
            }
        }
        Invoke-Scenario $results 'Scrape interval respects the tested 5 to 30 second contract' {
            foreach ($interval in @('5s', '15s', '30s')) {
                $config = Get-MonitorDefaults
                $config.ScrapeInterval = $interval
                Assert-True ((Test-MonitorConfig -Config $config).Valid) 'Supported scrape interval rejected.'
            }
            foreach ($interval in @('1s', '4s', '31s', '1m')) {
                $config = Get-MonitorDefaults
                $config.ScrapeInterval = $interval
                Assert-True (-not (Test-MonitorConfig -Config $config).Valid) 'Scrape interval outside tested contract accepted.'
            }
        }
        Invoke-Scenario $results 'Owner configuration requires matching HTTPS public hostname' {
            $config = Get-MonitorDefaults
            $config.Profile = 'owner'
            $config.PublicHostname = 'monitor.example.com'
            $config.GrafanaUrl = 'https://monitor.example.com'
            Assert-True ((Test-MonitorConfig -Config $config).Valid) 'Valid owner configuration rejected.'
            foreach ($hostname in @('', 'localhost', '-bad.example.com', 'example.com/path')) {
                $config.PublicHostname = $hostname
                Assert-True (-not (Test-MonitorConfig -Config $config).Valid) 'Invalid owner hostname accepted.'
            }
            $config.PublicHostname = 'monitor.example.com'
            foreach ($url in @('http://monitor.example.com', 'https://other.example.com', 'https://monitor.example.com/')) {
                $config.GrafanaUrl = $url
                Assert-True (-not (Test-MonitorConfig -Config $config).Valid) 'Mismatched owner URL accepted.'
            }
        }
        Invoke-Scenario $results 'Local mode rejects public hostname and remote UI URL' {
            $config = Get-MonitorDefaults
            $config.PublicHostname = 'monitor.example.com'
            Assert-True (-not (Test-MonitorConfig -Config $config).Valid) 'Local profile accepted public hostname.'
            $config = Get-MonitorDefaults
            $config.GrafanaUrl = 'http://0.0.0.0:3000'
            Assert-True (-not (Test-MonitorConfig -Config $config).Valid) 'Local profile accepted wildcard URL.'
        }
        Invoke-Scenario $results 'Timezones accept documented forms and reject control characters' {
            foreach ($timezone in @('browser', 'utc', 'Asia/Bangkok')) {
                $config = Get-MonitorDefaults
                $config.Timezone = $timezone
                Assert-True ((Test-MonitorConfig -Config $config).Valid) 'Documented timezone form rejected.'
            }
            foreach ($timezone in @('', 'not a timezone', "Asia/Bangkok`n[server]")) {
                $config = Get-MonitorDefaults
                $config.Timezone = $timezone
                Assert-True (-not (Test-MonitorConfig -Config $config).Valid) 'Invalid timezone accepted.'
            }
        }
        Invoke-Scenario $results 'Install and data roots reject relative, drive, system and overlapping paths' {
            foreach ($path in @('.', '..\escape', 'C:\', '\\server\share\monitor', $env:SystemRoot, 'C:\PCMonitor\..\Windows', 'C:\PCMonitor.', 'C:\PCMonitor ')) {
                $config = Get-MonitorDefaults
                $config.InstallRoot = $path
                Assert-True (-not (Test-MonitorConfig -Config $config).Valid) 'Unsafe install path accepted.'
            }
            foreach ($child in @('C:\PCMonitor', 'C:\PCMonitor\data', 'C:\PCMonitor/child')) {
                $config = Get-MonitorDefaults
                $config.InstallRoot = 'C:\PCMonitor'
                $config.DataRoot = $child
                Assert-True (-not (Test-MonitorConfig -Config $config).Valid) 'Overlapping roots accepted.'
            }
            $config = Get-MonitorDefaults
            $config.InstallRoot = Join-Path $env:SystemRoot 'System32\PCMonitor'
            Assert-True (-not (Test-MonitorConfig -Config $config).Valid) 'System child path accepted.'
        }
        Invoke-Scenario $results 'Regex fields reject invalid syntax and configuration injection' {
            foreach ($pattern in @('', '[', "app`ncollector: malicious", '(?<=x)y', '(x)\1')) {
                $config = Get-MonitorDefaults
                $config.ProcessInclude = $pattern
                Assert-True (-not (Test-MonitorConfig -Config $config).Valid) 'Invalid process inclusion expression accepted.'
            }
            $config = Get-MonitorDefaults
            $config.ProcessInclude = '(?i)example.*'
            Assert-True ((Test-MonitorConfig -Config $config).Valid) 'Documented case-insensitive simple regex rejected.'
        }
        Invoke-Scenario $results 'Overrides merge defaults and derive local URL from final port' {
            $basePath = Join-Path $testRoot 'base.psd1'
            $overridePath = Join-Path $testRoot 'override.psd1'
            [IO.File]::WriteAllText($basePath, "@{ GrafanaPort = 3001; RetentionTime = '7d' }")
            [IO.File]::WriteAllText($overridePath, "@{ GrafanaPort = 3002 }")
            $config = Read-MonitorConfig -Path $basePath -OverridePath $overridePath
            Assert-True ($config.GrafanaPort -eq 3002) 'Override did not win.'
            Assert-True ($config.RetentionTime -eq '7d') 'Base setting was lost.'
            Assert-True ($config.PrometheusPort -eq 9090) 'Defaults were lost.'
            Assert-True ($config.GrafanaUrl -eq 'http://localhost:3002') 'Local URL does not reflect final port.'
        }
        Invoke-Scenario $results 'Restricted data rejects execution without creating a sentinel' {
            $path = Join-Path $testRoot 'executable.psd1'
            $sentinelPath = Join-Path $testRoot 'must-not-exist.txt'
            $quotedPath = $sentinelPath.Replace("'", "''")
            [IO.File]::WriteAllText($path, "@{ Profile = (`$(Set-Content -LiteralPath '$quotedPath' -Value 'executed'); 'local') }")
            Assert-Throws { Read-MonitorConfig -Path $path } 'Executable PSD1 was accepted.'
            Assert-True (-not (Test-Path -LiteralPath $sentinelPath)) 'Restricted config executed a command.'
        }
        Invoke-Scenario $results 'Wrong extensions and missing files fail without side effects' {
            $wrongPath = Join-Path $testRoot 'config.env'
            [IO.File]::WriteAllText($wrongPath, "@{ Profile = 'local' }")
            Assert-Throws { Read-MonitorConfig -Path $wrongPath } 'Unsupported extension accepted.'
            Assert-Throws { Read-MonitorConfig -Path (Join-Path $testRoot 'missing.psd1') } 'Missing input accepted.'
        }
        Invoke-Scenario $results 'Secret provisioning WhatIf performs no write or elevation' {
            $secretRoot = Join-Path $testRoot 'secret-store'
            $secretValue = ConvertTo-SecureString ('qa-' + [Guid]::NewGuid().ToString('N')) -AsPlainText -Force
            Set-MonitorSecret -Name GrafanaAdminPassword -Value $secretValue -DataRoot $secretRoot -WhatIf
            Assert-True (-not (Test-Path -LiteralPath $secretRoot)) 'WhatIf created the secret store.'
        }
        Invoke-Scenario $results 'Secret interface rejects unrecognized names and path traversal' {
            foreach ($name in @('../escape', 'GrafanaAdminPassword/escape', 'OtherSecret', '')) {
                Assert-Throws { Get-MonitorSecretPath -Name $name -DataRoot $testRoot } 'Unsafe or unrecognized secret name accepted.'
            }
        }
    } finally {
        $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
        if (-not $resolvedTestRoot.StartsWith($temporaryParent + '\', [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedTestRoot) -notmatch '^PCMonitor-QA-[0-9a-f]{32}$') {
            throw 'Refusing to clean an unexpected temporary directory.'
        }
        if ([IO.Directory]::Exists($resolvedTestRoot)) { [IO.Directory]::Delete($resolvedTestRoot, $true) }
    }
    foreach ($result in $results) { Write-Output ('{0}: {1}{2}' -f $result.Status, $result.Name, $result.Detail) }
    $failed = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
    if ($failed -gt 0) { throw ('Configuration regression checks failed: ' + $failed) }
    Write-Output ('Configuration regression checks passed: ' + $results.Count)
}

function Invoke-Scenario {
    param([System.Collections.Generic.List[object]]$Results, [string]$Name, [scriptblock]$Scenario)
    try {
        & $Scenario | Out-Host
        $Results.Add([pscustomobject]@{ Status = 'PASS'; Name = $Name; Detail = '' })
    } catch {
        $Results.Add([pscustomobject]@{ Status = 'FAIL'; Name = $Name; Detail = ' - ' + $_.Exception.Message })
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    if (-not $threw) { throw $Message }
}

if (-not $RepositoryRoot) { $RepositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) }
Invoke-ConfigurationChecks -Root (Resolve-Path -LiteralPath $RepositoryRoot).Path
