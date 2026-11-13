Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Config.psm1')
Import-Module (Join-Path $PSScriptRoot 'Services.psm1')

function Get-MonitorStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Config, [switch]$Detailed)
    $validation = Test-MonitorConfig -Config $Config
    if (-not $validation.Valid) { throw 'Configuration validation failed.' }
    $checks = New-Object 'System.Collections.Generic.List[object]'
    $metadataPath = Join-Path $Config.DataRoot 'installation.json'
    $metadataValid = $false
    $ownershipValid = $false
    if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
        try {
            $metadata = [IO.File]::ReadAllText($metadataPath) | ConvertFrom-Json
            $metadataValid = ([IO.Path]::GetFullPath([string]$metadata.InstallRoot).TrimEnd('\') -eq [IO.Path]::GetFullPath($Config.InstallRoot).TrimEnd('\')) -and
                ([IO.Path]::GetFullPath([string]$metadata.DataRoot).TrimEnd('\') -eq [IO.Path]::GetFullPath($Config.DataRoot).TrimEnd('\'))
            if (-not $metadataValid) { throw 'Metadata does not match configuration.' }
            $checks.Add([pscustomobject]@{ Name = 'InstallationMetadata'; State = 'PASS'; Detail = 'Installation roots match the selected configuration.' })
            try {
                $installation = Get-MonitorInstallation -Config $Config
                Assert-MonitorOwnedServices -Config $Config -Installation $installation
                $ownershipValid = $true
                $checks.Add([pscustomobject]@{ Name = 'ServiceOwnership'; State = 'PASS'; Detail = 'Service executable paths and ownership evidence verified.' })
            } catch { $checks.Add([pscustomobject]@{ Name = 'ServiceOwnership'; State = 'FAIL'; Detail = 'Cannot verify owned service paths/metadata. Inspect installation with authorized service-query permissions.' }) }
        } catch { $checks.Add([pscustomobject]@{ Name = 'InstallationMetadata'; State = 'FAIL'; Detail = 'Metadata is unreadable or does not match configuration; no service ownership is inferred.' }) }
    } else {
        $checks.Add([pscustomobject]@{ Name = 'InstallationMetadata'; State = 'UNAVAILABLE'; Detail = 'Not installed at the selected DataRoot.' })
    }
    foreach ($name in @('PCMonitor-Exporter', 'PCMonitor-Prometheus', 'PCMonitor-Grafana')) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        $state = if ($metadataValid) { 'FAIL' } else { 'UNAVAILABLE' }; $detail = 'Required service is not installed.'
        if ($service) {
            $state = 'FAIL'; $detail = 'Service exists but ownership is not established.'
            if ($metadataValid -and $ownershipValid) { $state = if ($service.Status -eq 'Running') { 'PASS' } else { 'FAIL' }; $detail = [string]$service.Status }
        }
        $checks.Add([pscustomobject]@{ Name = $name; State = $state; Detail = $detail })
    }
    if ($metadataValid) {
        foreach ($endpoint in @(
            @{ Name = 'PrometheusReadiness'; Url = ('http://127.0.0.1:{0}/-/ready' -f $Config.PrometheusPort) },
            @{ Name = 'GrafanaHealth'; Url = ('http://127.0.0.1:{0}/api/health' -f $Config.GrafanaPort) }
        )) {
            try {
                $response = Invoke-WebRequest -UseBasicParsing -Uri $endpoint.Url -TimeoutSec 5 -ErrorAction Stop
                if ($response.StatusCode -ne 200) { throw 'Unhealthy endpoint.' }
                if ($endpoint.Name -eq 'GrafanaHealth') {
                    $health = $response.Content | ConvertFrom-Json
                    if ($health.database -ne 'ok') { throw 'Grafana database is not ready.' }
                }
                $checks.Add([pscustomobject]@{ Name = $endpoint.Name; State = 'PASS'; Detail = 'Loopback health endpoint is ready.' })
            } catch { $checks.Add([pscustomobject]@{ Name = $endpoint.Name; State = 'FAIL'; Detail = 'Loopback health endpoint is unavailable or unhealthy.' }) }
        }
        try {
            $targetsResponse = Invoke-RestMethod -Uri ('http://127.0.0.1:{0}/api/v1/targets' -f $Config.PrometheusPort) -TimeoutSec 5 -ErrorAction Stop
            $target = @($targetsResponse.data.activeTargets | Where-Object { $_.labels.job -eq 'windows_exporter' })
            if ($target.Count -ne 1 -or $target[0].health -ne 'up') { throw 'Exporter target not up.' }
            $checks.Add([pscustomobject]@{ Name = 'ExporterScrape'; State = 'PASS'; Detail = 'Prometheus reports exactly one UP Windows exporter target.' })
        } catch { $checks.Add([pscustomobject]@{ Name = 'ExporterScrape'; State = 'FAIL'; Detail = 'Windows exporter target is missing, down, ambiguous, or Prometheus cannot be reached.' }) }
        try {
            $collectorQuery = [Uri]::EscapeDataString('windows_exporter_collector_success{job="windows_exporter",instance="local"}')
            $collectorResponse = Invoke-RestMethod -Uri ('http://127.0.0.1:{0}/api/v1/query?query={1}' -f $Config.PrometheusPort, $collectorQuery) -TimeoutSec 5 -ErrorAction Stop
            $collectors = @($collectorResponse.data.result)
            $expectedCollectors = @('cpu', 'memory', 'logical_disk', 'physical_disk', 'net', 'os', 'system', 'process', 'service')
            foreach ($collector in $expectedCollectors) {
                $series = @($collectors | Where-Object { $_.metric.collector -eq $collector })
                if ($series.Count -ne 1 -or [string]$series[0].value[1] -ne '1') { throw 'Required collector is missing or failed.' }
            }
            $checks.Add([pscustomobject]@{ Name = 'RequiredCollectors'; State = 'PASS'; Detail = 'All nine required collectors report success.' })
        } catch { $checks.Add([pscustomobject]@{ Name = 'RequiredCollectors'; State = 'FAIL'; Detail = 'One or more required collectors are missing, failed, or cannot be queried; target UP alone is insufficient.' }) }
        try {
            $query = [Uri]::EscapeDataString('max(time() - timestamp(windows_exporter_collector_success{job="windows_exporter",instance="local"}))')
            $ageResult = Invoke-RestMethod -Uri ('http://127.0.0.1:{0}/api/v1/query?query={1}' -f $Config.PrometheusPort, $query) -TimeoutSec 5 -ErrorAction Stop
            if (@($ageResult.data.result).Count -eq 0) { throw 'No collector samples.' }
            $age = [double]::Parse([string]$ageResult.data.result[0].value[1], [Globalization.CultureInfo]::InvariantCulture)
            $maxAge = 3 * [int]$Config.ScrapeInterval.TrimEnd('s')
            $ageState = if (-not [double]::IsNaN($age) -and $age -ge 0 -and $age -le $maxAge) { 'PASS' } else { 'FAIL' }
            $checks.Add([pscustomobject]@{ Name = 'TelemetryAge'; State = $ageState; Detail = ('Oldest collector sample age: {0:N1} seconds; expected at most {1}.' -f $age, $maxAge) })
        } catch { $checks.Add([pscustomobject]@{ Name = 'TelemetryAge'; State = 'FAIL'; Detail = 'Unable to verify required collector sample freshness.' }) }
        if ($Detailed) {
            try {
                $stats = Invoke-RestMethod -Uri ('http://127.0.0.1:{0}/api/v1/status/tsdb' -f $Config.PrometheusPort) -TimeoutSec 5 -ErrorAction Stop
                $series = [long]$stats.data.headStats.numSeries
                $checks.Add([pscustomobject]@{ Name = 'ActiveSeries'; State = 'PASS'; Detail = ('{0} active series; configured per-scrape sample limit is 50000.' -f $series) })
            } catch { $checks.Add([pscustomobject]@{ Name = 'ActiveSeries'; State = 'UNKNOWN'; Detail = 'TSDB statistics unavailable.' }) }
        }
    }
    if ($Detailed) {
        $checks.Add([pscustomobject]@{ Name = 'HardwareSensors'; State = 'UNSUPPORTED'; Detail = 'Hardware sensors and SMART are not installed in the core profile; no health conclusion is made.' })
        try {
            $driveRoot = [IO.Path]::GetPathRoot($Config.DataRoot)
            $drive = New-Object IO.DriveInfo($driveRoot)
            $freeRatio = $drive.AvailableFreeSpace / [double]$drive.TotalSize
            $driveState = if ($freeRatio -lt 0.05) { 'FAIL' } elseif ($freeRatio -lt 0.15) { 'WARNING' } else { 'PASS' }
            $checks.Add([pscustomobject]@{ Name = 'MonitoringDriveSpace'; State = $driveState; Detail = ('{0:P1} available; retention size is not a hard filesystem quota.' -f $freeRatio) })
        } catch { $checks.Add([pscustomobject]@{ Name = 'MonitoringDriveSpace'; State = 'UNKNOWN'; Detail = 'Unable to read free space.' }) }
        $checks.Add([pscustomobject]@{ Name = 'RebootVerification'; State = 'UNKNOWN'; Detail = 'A live status check does not prove startup before login after reboot.' })
    }
    $overall = 'Healthy'
    if (@($checks | Where-Object State -eq 'FAIL').Count -gt 0) { $overall = 'Unhealthy' }
    elseif (-not $metadataValid) { $overall = 'NotInstalled' }
    elseif (@($checks | Where-Object State -in @('WARNING', 'UNKNOWN', 'UNAVAILABLE')).Count -gt 0) { $overall = 'Degraded' }
    return [pscustomobject]@{ SchemaVersion = 1; TimestampUtc = [DateTime]::UtcNow.ToString('o'); OverallState = $overall; Checks = $checks.ToArray() }
}

Export-ModuleMember -Function Get-MonitorStatus
