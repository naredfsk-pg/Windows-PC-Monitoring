[CmdletBinding()]
param([string]$RepositoryRoot)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if (-not $RepositoryRoot) { $RepositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) }
. (Join-Path $RepositoryRoot 'tests/TestSupport.ps1')

function Invoke-DiagnosticsChecks {
    param([string]$Root)
    Import-Module (Join-Path $Root 'scripts/lib/Config.psm1') -Force
    $module = Import-Module (Join-Path $Root 'scripts/lib/Diagnostics.psm1') -Force -PassThru
    $results = New-Object System.Collections.Generic.List[object]
    $testRoot = New-QATemporaryDirectory
    try {
        $config = Get-MonitorDefaults
        $config.InstallRoot = Join-Path $testRoot 'install'
        $config.DataRoot = Join-Path $testRoot 'data'
        [IO.Directory]::CreateDirectory($config.DataRoot) | Out-Null
        @{ InstallRoot = $config.InstallRoot; DataRoot = $config.DataRoot } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $config.DataRoot 'installation.json') -Encoding UTF8
        Install-DiagnosticBoundaryDoubles -Module $module
        Invoke-QACase $results 'Healthy owned services and all required fresh collectors produce Healthy' {
            $status = Invoke-DiagnosticScenario -Module $module -Config $config -Scenario Healthy
            Assert-QATrue ($status.OverallState -eq 'Healthy') 'Healthy baseline did not produce Healthy.'
        }
        foreach ($scenario in @('FailedCollector', 'MissingCollector', 'DuplicateCollector')) {
            Invoke-QACase $results ('UP target cannot mask collector failure: ' + $scenario) {
                $status = Invoke-DiagnosticScenario -Module $module -Config $config -Scenario $scenario
                Assert-CheckState -Status $status -Name ExporterScrape -Expected PASS
                Assert-CheckState -Status $status -Name RequiredCollectors -Expected FAIL
                Assert-QATrue ($status.OverallState -eq 'Unhealthy') 'Required collector defect did not make the status unhealthy.'
            }
        }
        foreach ($scenario in @('MissingService', 'StoppedService', 'OwnershipFailure')) {
            Invoke-QACase $results ('Fresh telemetry cannot mask service defect: ' + $scenario) {
                $status = Invoke-DiagnosticScenario -Module $module -Config $config -Scenario $scenario
                Assert-QATrue ($status.OverallState -eq 'Unhealthy') 'Service defect did not make the status unhealthy.'
                $check = if ($scenario -eq 'OwnershipFailure') { 'ServiceOwnership' } else { 'PCMonitor-Grafana' }
                Assert-CheckState -Status $status -Name $check -Expected FAIL
            }
        }
        foreach ($scenario in @('StaleSamples', 'NotANumberAge', 'MissingAge', 'QueryTimeout')) {
            Invoke-QACase $results ('Invalid or unavailable freshness fails explicitly: ' + $scenario) {
                $status = Invoke-DiagnosticScenario -Module $module -Config $config -Scenario $scenario
                Assert-CheckState -Status $status -Name TelemetryAge -Expected FAIL
                Assert-QATrue ($status.OverallState -eq 'Unhealthy') 'Freshness defect did not make the status unhealthy.'
            }
        }
        foreach ($scenario in @('DuplicateTarget', 'DownTarget', 'BrokenGrafanaDatabase')) {
            Invoke-QACase $results ('Endpoint inconsistency is unhealthy: ' + $scenario) {
                $status = Invoke-DiagnosticScenario -Module $module -Config $config -Scenario $scenario
                Assert-QATrue ($status.OverallState -eq 'Unhealthy') 'Endpoint defect did not make the status unhealthy.'
            }
        }
    } finally {
        Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue
        Remove-QATemporaryDirectory -Path $testRoot
    }
    Complete-QACases -Results $results -Suite 'Diagnostics boundary regression'
}

function Install-DiagnosticBoundaryDoubles {
    param([System.Management.Automation.PSModuleInfo]$Module)
    & $Module {
        $script:QAScenario = 'Healthy'
        function script:Get-MonitorInstallation { param($Config) return [pscustomobject]@{ InstallRoot = $Config.InstallRoot; DataRoot = $Config.DataRoot } }
        function script:Assert-MonitorOwnedServices { param($Config, $Installation) if ($script:QAScenario -eq 'OwnershipFailure') { throw 'Synthetic service ownership mismatch.' } }
        function script:Get-Service {
            param([string]$Name, $ErrorAction)
            if ($Name -eq 'PCMonitor-Grafana' -and $script:QAScenario -eq 'MissingService') { return $null }
            $state = if ($Name -eq 'PCMonitor-Grafana' -and $script:QAScenario -eq 'StoppedService') { 'Stopped' } else { 'Running' }
            return [pscustomobject]@{ Name = $Name; Status = $state }
        }
        function script:Invoke-WebRequest {
            param($Uri, [switch]$UseBasicParsing, $TimeoutSec, $ErrorAction)
            $database = if ($script:QAScenario -eq 'BrokenGrafanaDatabase') { 'failed' } else { 'ok' }
            return [pscustomobject]@{ StatusCode = 200; Content = ('{"database":"' + $database + '"}') }
        }
        function script:Invoke-RestMethod {
            param($Uri, $TimeoutSec, $ErrorAction)
            if ($script:QAScenario -eq 'QueryTimeout') { throw 'Synthetic query timeout.' }
            if ($Uri -match '/targets$') {
                $health = if ($script:QAScenario -eq 'DownTarget') { 'down' } else { 'up' }
                $targets = @([pscustomobject]@{ labels = @{ job = 'windows_exporter' }; health = $health })
                if ($script:QAScenario -eq 'DuplicateTarget') { $targets += $targets[0] }
                return [pscustomobject]@{ data = @{ activeTargets = $targets } }
            }
            $decodedUri = [Uri]::UnescapeDataString([string]$Uri)
            if ($decodedUri -match 'max\(time\(\)') {
                $age = switch ($script:QAScenario) { 'StaleSamples' { '90' }; 'NotANumberAge' { 'NaN' }; default { '0' } }
                $samples = @([pscustomobject]@{ value = @(1000, $age) })
                if ($script:QAScenario -eq 'MissingAge') { $samples = @() }
                return [pscustomobject]@{ data = @{ result = $samples } }
            }
            $series = @()
            foreach ($collector in @('cpu', 'memory', 'logical_disk', 'physical_disk', 'net', 'os', 'system', 'process', 'service')) {
                if ($collector -eq 'net' -and $script:QAScenario -eq 'MissingCollector') { continue }
                $success = if ($collector -eq 'net' -and $script:QAScenario -eq 'FailedCollector') { '0' } else { '1' }
                $series += [pscustomobject]@{ metric = @{ collector = $collector }; value = @(1000, $success) }
            }
            if ($script:QAScenario -eq 'DuplicateCollector') { $series += $series[0] }
            return [pscustomobject]@{ data = @{ result = $series } }
        }
    }
}

function Invoke-DiagnosticScenario {
    param([System.Management.Automation.PSModuleInfo]$Module, [System.Collections.IDictionary]$Config, [string]$Scenario)
    return & $Module { param($SelectedConfig, $SelectedScenario) $script:QAScenario = $SelectedScenario; Get-MonitorStatus -Config $SelectedConfig } $Config $Scenario
}

function Assert-CheckState {
    param($Status, [string]$Name, [string]$Expected)
    $check = @($Status.Checks | Where-Object Name -eq $Name)
    Assert-QATrue ($check.Count -eq 1 -and $check[0].State -eq $Expected) ('Unexpected diagnostic state for ' + $Name)
}

Invoke-DiagnosticsChecks -Root (Resolve-Path -LiteralPath $RepositoryRoot).Path
