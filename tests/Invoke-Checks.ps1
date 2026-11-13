[CmdletBinding()]
param(
    [ValidateSet('Foundation', 'Core')]
    [string]$Stage = 'Core',
    [string]$RepositoryRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Invoke-RepositoryChecks {
    param([string]$Root, [string]$SelectedStage)

    $checks = New-Object System.Collections.Generic.List[object]
    Add-Check $checks 'Required foundation deliverables exist' {
        $required = @(
            'LICENSE', '.gitignore', 'config/dependencies.lock.json',
            'docs/ARCHITECTURE.md', 'docs/DEPENDENCIES.md',
            'docs/contracts/configuration.md', 'docs/contracts/services.md',
            'docs/contracts/operations.md', 'docs/contracts/metrics.md'
        )
        Assert-RequiredFiles $Root $required
    }
    Add-Check $checks 'Dependency lock has safe and complete distribution metadata' {
        Assert-DependencyLock (Join-Path $Root 'config/dependencies.lock.json')
    }

    $sourceFiles = @(Get-RepositorySourceFiles $Root)
    Add-Check $checks 'PowerShell sources parse without execution' {
        foreach ($file in $sourceFiles | Where-Object { $_ -match '\.(ps1|psm1|psd1)$' }) {
            $parseTokens = $null
            $parseErrors = $null
            [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root $file), [ref]$parseTokens, [ref]$parseErrors) | Out-Null
            if ($parseErrors.Count -gt 0) { throw ('PowerShell parse failure in {0}, line {1}.' -f $file, $parseErrors[0].Extent.StartLineNumber) }
        }
    }
    Add-Check $checks 'Checked-in JSON assets parse' {
        foreach ($file in $sourceFiles | Where-Object { $_ -match '\.json$' }) {
            try { Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root $file) | ConvertFrom-Json | Out-Null }
            catch { throw ('Invalid JSON asset: ' + $file) }
        }
    }
    Add-Check $checks 'Source inventory excludes local credentials and runtime data' {
        $trackedFiles = @(& git -C $Root ls-files)
        if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect tracked file inventory.' }
        foreach ($file in $trackedFiles) {
            if ($file -match '(^|/)(\.env($|\.)|[^/]+\.local\.(env|psd1)$)' -and $file -notmatch '(^|/)\.env\.example$') {
                throw ('Local configuration is tracked: ' + $file)
            }
            if ($file -match '^(data|logs|downloads|backups|config/generated|artifacts/local)/') { throw ('Runtime artifact is tracked: ' + $file) }
        }
    }
    Add-Check $checks 'Source assets contain no recognized live credential formats' {
        $patterns = @(
            'eyJ[A-Za-z0-9_-]{60,}(?:\.[A-Za-z0-9_-]+){0,2}',
            '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
            'https://(?:hc-ping\.com|healthchecks\.io/ping)/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        )
        foreach ($file in $sourceFiles) {
            $content = [IO.File]::ReadAllText((Join-Path $Root $file))
            foreach ($pattern in $patterns) {
                if ($content -match $pattern) { throw ('Credential-shaped material found in ' + $file + '; value intentionally omitted.') }
            }
        }
    }

    if ($SelectedStage -eq 'Core') {
        Add-Check $checks 'Required core implementation deliverables exist' {
            $required = @(
                'scripts/lib/Config.psm1', 'scripts/lib/Secrets.psm1',
                'scripts/lib/Artifacts.psm1', 'scripts/lib/Services.psm1', 'scripts/lib/Diagnostics.psm1',
                'scripts/validate-config.ps1', 'scripts/install.ps1', 'scripts/uninstall.ps1',
                'scripts/start.ps1', 'scripts/stop.ps1', 'scripts/status.ps1', 'scripts/doctor.ps1',
                'scripts/backup.ps1', 'scripts/restore.ps1', 'config/schema.json',
                'config/local.example.psd1', 'config/owner.example.psd1',
                'config/prometheus.yml.tpl', 'config/grafana/grafana.ini.tpl',
                'config/grafana/dashboards/overview.json', 'config/grafana/dashboards/processes.json'
            )
            Assert-RequiredFiles $Root $required
        }
        Add-Check $checks 'Dashboard identities and data sources are explicit' {
            $dashboardUids = @()
            foreach ($dashboardName in @('overview', 'processes')) {
                $path = Join-Path $Root ('config/grafana/dashboards/' + $dashboardName + '.json')
                $dashboard = Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json
                if (-not $dashboard.uid -or -not $dashboard.title -or @($dashboard.panels).Count -eq 0) { throw ('Dashboard lacks identity or panels: ' + $dashboardName) }
                if ($dashboardUids -contains $dashboard.uid) { throw 'Dashboard UID is duplicated.' }
                $dashboardUids += $dashboard.uid
                if (-not $dashboard.time.from -or -not $dashboard.time.to) { throw ('Dashboard lacks default time range: ' + $dashboardName) }
            }
        }
        Add-Check $checks 'Configuration behavior regression suite exists and passes' {
            $suite = Join-Path $Root 'tests/config/Invoke-ConfigChecks.ps1'
            Assert-RequiredFiles $Root @('tests/config/Invoke-ConfigChecks.ps1')
            & $suite -RepositoryRoot $Root
        }
        Add-Check $checks 'Rendering and secret-store safety regressions pass' {
            Assert-RequiredFiles $Root @('tests/config/Invoke-RendererChecks.ps1', 'tests/TestSupport.ps1')
            & (Join-Path $Root 'tests/config/Invoke-RendererChecks.ps1') -RepositoryRoot $Root
        }
        Add-Check $checks 'Diagnostics fail safely at service and HTTP boundaries' {
            Assert-RequiredFiles $Root @('tests/powershell/Invoke-DiagnosticsChecks.ps1')
            & (Join-Path $Root 'tests/powershell/Invoke-DiagnosticsChecks.ps1') -RepositoryRoot $Root
        }
        Add-Check $checks 'Lifecycle dry-run and artifact refusals preserve host state' {
            Assert-RequiredFiles $Root @('tests/powershell/Invoke-LifecycleChecks.ps1')
            & (Join-Path $Root 'tests/powershell/Invoke-LifecycleChecks.ps1') -RepositoryRoot $Root
        }
    }

    foreach ($check in $checks) { Write-Output ('{0}: {1}{2}' -f $check.Status, $check.Name, $check.Detail) }
    $failed = @($checks | Where-Object { $_.Status -eq 'FAIL' }).Count
    Write-Output ('Stage={0}; checks={1}; failed={2}. Static/local checks do not certify Windows services, hardware, email, or remote access.' -f $SelectedStage, $checks.Count, $failed)
    return $failed
}

function Add-Check {
    param([System.Collections.Generic.List[object]]$Results, [string]$Name, [scriptblock]$Check)
    try {
        & $Check | Out-Host
        $Results.Add([pscustomobject]@{ Status = 'PASS'; Name = $Name; Detail = '' })
    } catch {
        $Results.Add([pscustomobject]@{ Status = 'FAIL'; Name = $Name; Detail = ' - ' + $_.Exception.Message })
    }
}

function Assert-RequiredFiles {
    param([string]$Root, [string[]]$Paths)
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $path) -PathType Leaf)) { throw ('Missing required file: ' + $path) }
    }
}

function Assert-DependencyLock {
    param([string]$Path)
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or $manifest.platform -ne 'windows-x64') { throw 'Unsupported dependency manifest schema/platform.' }
    $ids = @()
    foreach ($component in @($manifest.components)) {
        foreach ($key in @('id', 'version', 'url', 'sha256', 'archiveType', 'executableRelativePath', 'license', 'serviceStrategy')) {
            if (-not $component.PSObject.Properties[$key] -or -not $component.$key) { throw ('Dependency field missing: ' + $key) }
        }
        if ($ids -contains $component.id) { throw 'Duplicate dependency component ID.' }
        $ids += $component.id
        if ($component.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or $component.sha256 -match '^([0-9a-fA-F])\1{63}$') { throw ('Invalid SHA-256 for component ' + $component.id) }
        $uri = $null
        if (-not [Uri]::TryCreate([string]$component.url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw ('Unsafe artifact URL for component ' + $component.id) }
        if (@('github.com', 'dl.grafana.com') -notcontains $uri.DnsSafeHost) { throw ('Unapproved distribution host for component ' + $component.id) }
        if ([IO.Path]::IsPathRooted([string]$component.executableRelativePath) -or $component.executableRelativePath -match '(^|[\\/])\.\.([\\/]|$)') { throw ('Unsafe executable path for component ' + $component.id) }
    }
    foreach ($id in @('windows_exporter', 'prometheus', 'grafana', 'winsw')) {
        if ($ids -notcontains $id) { throw ('Missing core dependency component: ' + $id) }
    }
}

function Get-RepositorySourceFiles {
    param([string]$Root)
    $files = @(& git -C $Root ls-files --cached --others --exclude-standard)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate repository source assets.' }
    return @($files | Where-Object {
        $_ -match '^(scripts/|config/|tests/|docs/|\.github/|README\.md$|THIRD_PARTY_NOTICES\.md$)' -and
        $_ -notmatch '(^|/)\.env($|\.)' -and $_ -notmatch '\.local\.(env|psd1)$' -and
        $_ -match '\.(ps1|psm1|psd1|json|ya?ml|tpl|md|txt)$'
    } | Sort-Object -Unique)
}

if (-not $RepositoryRoot) { $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$resolvedRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$output = @(Invoke-RepositoryChecks $resolvedRoot $Stage)
$failedCount = [int]$output[-1]
$output | Select-Object -SkipLast 1 | ForEach-Object { Write-Output $_ }
if ($failedCount -gt 0) { exit 1 }
exit 0
