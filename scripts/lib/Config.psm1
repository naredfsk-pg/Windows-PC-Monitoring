Set-StrictMode -Version Latest

function Get-MonitorDefaults {
    $programFilesPath = [Environment]::GetFolderPath('ProgramFiles')
    $programDataPath = [Environment]::GetFolderPath('CommonApplicationData')
    return @{
        Profile = 'local'; InstallRoot = (Join-Path $programFilesPath 'PCMonitor')
        DataRoot = (Join-Path $programDataPath 'PCMonitor')
        GrafanaPort = 3000; PrometheusPort = 9090; ExporterPort = 9182
        ScrapeInterval = '15s'; RetentionTime = '30d'; RetentionSize = '10GB'
        PublicHostname = ''; GrafanaUrl = 'http://localhost:3000'; Timezone = 'browser'
        ProcessInclude = '.+'; ProcessExclude = ''
    }
}

function Test-MonitorConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Config)
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $defaults = Get-MonitorDefaults
    foreach ($key in $Config.Keys) {
        if (-not $defaults.ContainsKey([string]$key)) { $errors.Add('Unknown configuration key. Only documented schema keys are accepted.') }
    }
    foreach ($key in $defaults.Keys) {
        if (-not $Config.Contains($key)) { $errors.Add("Missing configuration key: $key"); continue }
        if ($key -notin @('GrafanaPort', 'PrometheusPort', 'ExporterPort')) {
            if ($Config[$key] -isnot [string] -or $Config[$key] -match '[\x00-\x1f\x7f]') {
                $errors.Add("$key must be a string without control characters.")
            }
        }
    }
    if ($errors.Count -gt 0) { return [pscustomobject]@{ Valid = $false; Errors = $errors.ToArray() } }
    if ($Config.Profile -notin @('local', 'owner')) { $errors.Add('Profile must be local or owner.') }
    $ports = @()
    foreach ($key in @('GrafanaPort', 'PrometheusPort', 'ExporterPort')) {
        $value = $Config[$key]
        if (($value -isnot [int] -and $value -isnot [long]) -or $value -lt 1024 -or $value -gt 65535) {
            $errors.Add("$key must be an integer between 1024 and 65535.")
        } else { $ports += [int]$value }
    }
    if (@($ports | Select-Object -Unique).Count -ne $ports.Count) { $errors.Add('Service ports must be distinct.') }
    if ($Config.ScrapeInterval -notmatch '^(?:[5-9]|[12][0-9]|30)s$') { $errors.Add('ScrapeInterval must be between 5s and 30s for the supported core rate windows.') }
    if ($Config.RetentionTime -notmatch '^[1-9][0-9]*(h|d|w)$') { $errors.Add('RetentionTime must be a positive duration in h, d or w.') }
    if ($Config.RetentionSize -notmatch '^[1-9][0-9]*(MB|GB|TB)$') { $errors.Add('RetentionSize must use a positive integer followed by MB, GB or TB.') }
    $normalizedPaths = @{}
    foreach ($key in @('InstallRoot', 'DataRoot')) {
        $value = $Config[$key]
        try {
            if ($value -notmatch '^[A-Za-z]:[\\/]' -or $value -match '["<>|?*{};#\x27]' -or $value.Substring(2).Contains(':')) { throw 'Invalid local absolute path.' }
            if ($value -match '(^|[\\/])\.{1,2}([\\/]|$)|[\\/][^\\/]*[. ]([\\/]|$)') { throw 'Traversal and trailing-dot/space aliases are not allowed.' }
            $fullPath = [IO.Path]::GetFullPath($value).TrimEnd('\', '/')
            $driveRoot = [IO.Path]::GetPathRoot($fullPath).TrimEnd('\', '/')
            if ($fullPath -eq $driveRoot) { throw 'Drive roots are not allowed.' }
            $windowsPath = [Environment]::GetFolderPath('Windows')
            if ($windowsPath -and ($fullPath -eq $windowsPath -or $fullPath.StartsWith($windowsPath + '\', [StringComparison]::OrdinalIgnoreCase))) {
                throw 'Windows system directories are not allowed.'
            }
            $normalizedPaths[$key] = $fullPath
        } catch { $errors.Add("$key must be a dedicated local absolute directory outside Windows system directories.") }
    }
    if ($normalizedPaths.Count -eq 2) {
        $installPath = $normalizedPaths.InstallRoot; $dataPath = $normalizedPaths.DataRoot
        if ($installPath -eq $dataPath -or $installPath.StartsWith($dataPath + '\', [StringComparison]::OrdinalIgnoreCase) -or $dataPath.StartsWith($installPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
            $errors.Add('InstallRoot and DataRoot must be separate, non-overlapping directories.')
        }
    }
    $hostnamePattern = '^(?=.{1,253}$)(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$'
    if ($Config.Profile -eq 'owner') {
        if ($Config.PublicHostname -notmatch $hostnamePattern) { $errors.Add('Owner profile requires a complete public hostname.') }
        if ($Config.GrafanaUrl -cne ('https://' + $Config.PublicHostname)) { $errors.Add('Owner GrafanaUrl must equal https:// followed by PublicHostname, without a trailing slash.') }
    } else {
        if ($Config.PublicHostname -ne '') { $errors.Add('Local profile must leave PublicHostname empty.') }
        if ($Config.GrafanaUrl -ne ('http://localhost:' + $Config.GrafanaPort)) { $errors.Add('Local GrafanaUrl must match http://localhost:<GrafanaPort>.') }
    }
    if ($Config.Timezone -notmatch '^(browser|utc|[A-Za-z_+-]+/[A-Za-z0-9_+/-]+)$') { $errors.Add('Timezone must be browser, utc or an IANA timezone identifier.') }
    foreach ($key in @('ProcessInclude', 'ProcessExclude')) {
        $pattern = $Config[$key]
        $simplePattern = $pattern -replace '^\(\?i\)', ''
        if ($pattern.Length -gt 512 -or $simplePattern -match '\(\?|\\[1-9]|\\[kg]') {
            $errors.Add("$key must use the supported simple RE2-compatible pattern subset (no lookarounds or backreferences; maximum 512 characters).")
            continue
        }
        try { $null = New-Object System.Text.RegularExpressions.Regex($Config[$key]) } catch { $errors.Add("$key must be a valid regular expression.") }
    }
    if ($Config.ProcessInclude.Length -eq 0) { $errors.Add('ProcessInclude cannot be empty.') }
    return [pscustomobject]@{ Valid = ($errors.Count -eq 0); Errors = $errors.ToArray() }
}

function Read-MonitorConfig {
    [CmdletBinding()]
    param([string]$Path, [string]$OverridePath)
    $config = Get-MonitorDefaults
    $urlExplicit = $false
    foreach ($inputPath in @($Path, $OverridePath)) {
        if (-not $inputPath) { continue }
        if ([IO.Path]::GetExtension($inputPath) -ne '.psd1') { throw 'Configuration files must use the .psd1 restricted data format.' }
        try { $values = Import-PowerShellDataFile -LiteralPath $inputPath -ErrorAction Stop } catch { throw 'Unable to read restricted configuration data. Check the file path and .psd1 syntax; executable expressions are not supported.' }
        foreach ($key in $values.Keys) { $config[$key] = $values[$key] }
        if ($values.ContainsKey('GrafanaUrl')) { $urlExplicit = $true }
    }
    # Changing the local port also changes the default public-facing URL unless explicitly set.
    if (-not $urlExplicit -and $config.Profile -eq 'local') { $config.GrafanaUrl = 'http://localhost:' + $config.GrafanaPort }
    $validation = Test-MonitorConfig -Config $config
    if (-not $validation.Valid) { throw ('Invalid monitor configuration: ' + ($validation.Errors -join ' ')) }
    return $config
}

function Write-MonitorConfiguration {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [string]$RepositoryRoot = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
    )
    $validation = Test-MonitorConfig -Config $Config
    if (-not $validation.Valid) { throw ('Invalid monitor configuration: ' + ($validation.Errors -join ' ')) }
    $RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\', '/')
    $outputRoot = [IO.Path]::GetFullPath($OutputPath)
    if ($outputRoot.TrimEnd('\', '/') -eq [IO.Path]::GetPathRoot($outputRoot).TrimEnd('\', '/')) { throw 'Configuration output cannot be a drive root.' }
    function Assert-NoReparsePoint([string]$Path) {
        $cursor = [IO.Path]::GetFullPath($Path)
        while ($cursor) {
            if (Test-Path -LiteralPath $cursor) {
                if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Configuration paths cannot contain reparse points.' }
            }
            $parentPath = Split-Path -Parent $cursor
            if ($parentPath -eq $cursor) { break }
            $cursor = $parentPath
        }
    }
    Assert-NoReparsePoint $outputRoot
    $forwardData = ([IO.Path]::GetFullPath($Config.DataRoot)).Replace('\', '/')
    $forwardOutput = $outputRoot.Replace('\', '/')
    $tokens = @{
        EXPORTER_PORT = [string]$Config.ExporterPort; PROMETHEUS_PORT = [string]$Config.PrometheusPort
        GRAFANA_PORT = [string]$Config.GrafanaPort; SCRAPE_INTERVAL = $Config.ScrapeInterval
        RETENTION_TIME = $Config.RetentionTime; RETENTION_SIZE = $Config.RetentionSize
        GRAFANA_URL = $Config.GrafanaUrl; TIMEZONE = $Config.Timezone
        GRAFANA_COOKIE_SECURE = if ($Config.Profile -eq 'owner') { 'true' } else { 'false' }
        PROMETHEUS_DATA_PATH = "$forwardData/data/prometheus"; GRAFANA_DATA_PATH = "$forwardData/data/grafana"
        GRAFANA_LOG_PATH = "$forwardData/logs/grafana"; GRAFANA_PROVISIONING_PATH = "$forwardOutput/grafana/provisioning"
        GRAFANA_ADMIN_SECRET_PATH = "$forwardData/secrets/grafana-admin-password"
        GRAFANA_DASHBOARDS_PATH = "$forwardOutput/grafana/dashboards"
        PROCESS_INCLUDE_YAML = "'" + $Config.ProcessInclude.Replace("'", "''") + "'"
        PROCESS_EXCLUDE_YAML = "'" + $Config.ProcessExclude.Replace("'", "''") + "'"
    }
    $sources = @(
        @{ Source = 'config/prometheus.yml.tpl'; Target = 'prometheus/prometheus.yml' },
        @{ Source = 'config/grafana/grafana.ini.tpl'; Target = 'grafana/grafana.ini' }
    )
    foreach ($mapping in @(
        @{ Source = 'config/exporters'; Target = 'exporters'; Filter = '*.yml*' },
        @{ Source = 'config/recording-rules'; Target = 'prometheus/rules'; Filter = '*.yml' },
        @{ Source = 'config/grafana/provisioning'; Target = 'grafana/provisioning'; Filter = '*.yml*' },
        @{ Source = 'config/grafana/dashboards'; Target = 'grafana/dashboards'; Filter = '*.json' }
    )) {
        $sourceRoot = Join-Path $RepositoryRoot $mapping.Source
        if (-not (Test-Path -LiteralPath $sourceRoot)) { throw ('Required configuration directory missing: ' + $mapping.Source) }
        Assert-NoReparsePoint $sourceRoot
        foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Filter $mapping.Filter) {
            $relativePath = $file.FullName.Substring($sourceRoot.Length).TrimStart('\', '/') -replace '\.tpl$', ''
            $sources += @{ Source = $file.FullName; Target = (Join-Path $mapping.Target $relativePath) }
        }
    }
    $rendered = @()
    foreach ($source in $sources) {
        $sourcePath = $source.Source
        if (-not [IO.Path]::IsPathRooted($sourcePath)) { $sourcePath = Join-Path $RepositoryRoot $sourcePath }
        Assert-NoReparsePoint $sourcePath
        $content = [IO.File]::ReadAllText($sourcePath)
        foreach ($key in $tokens.Keys) { $content = $content.Replace('{{' + $key + '}}', $tokens[$key]) }
        foreach ($placeholder in [regex]::Matches($content, '\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}')) {
            $allowedLegends = @('volume', 'nic', 'process', 'process_id', 'core', 'mode', 'instance', 'job')
            if ($source.Target -match '\.json$' -and $allowedLegends -ccontains $placeholder.Groups[1].Value) { continue }
            throw ('Unresolved configuration token in ' + $source.Target)
        }
        $destinationPath = [IO.Path]::GetFullPath((Join-Path $outputRoot $source.Target))
        if (-not $destinationPath.StartsWith($outputRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Rendered file is outside the configuration output directory.' }
        Assert-NoReparsePoint $destinationPath
        $rendered += [pscustomobject]@{ Path = $destinationPath; Content = $content }
    }
    if ($PSCmdlet.ShouldProcess($outputRoot, 'Write rendered monitor configuration (no plaintext secrets)')) {
        foreach ($file in $rendered) {
            $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file.Path))
            [IO.File]::WriteAllText($file.Path, $file.Content, (New-Object Text.UTF8Encoding($false)))
        }
        return $rendered | ForEach-Object { $_.Path }
    }
}

Export-ModuleMember -Function Get-MonitorDefaults, Test-MonitorConfig, Read-MonitorConfig, Write-MonitorConfiguration
