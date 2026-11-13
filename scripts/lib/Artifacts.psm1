Set-StrictMode -Version Latest

function Read-MonitorManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    try { $manifest = Get-Content -Raw -LiteralPath $Path -Encoding UTF8 | ConvertFrom-Json } catch { throw 'Dependency manifest could not be read.' }
    if ($manifest.schemaVersion -ne 1 -or $manifest.platform -ne 'windows-x64') { throw 'Unsupported dependency manifest schema or platform.' }
    $expectedIds = @('prometheus', 'windows_exporter', 'grafana', 'winsw')
    if (@($manifest.components).Count -ne $expectedIds.Count) { throw 'Dependency manifest must contain the four required core components.' }
    foreach ($component in $manifest.components) {
        Assert-MonitorComponent -Component $component
        if ($component.id -notin $expectedIds) { throw 'Unexpected component in dependency manifest.' }
    }
    if (@($manifest.components.id | Select-Object -Unique).Count -ne $expectedIds.Count) { throw 'Dependency manifest component IDs must be unique.' }
    return $manifest
}

function Get-MonitorArtifact {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)]$Component, [Parameter(Mandatory = $true)][string]$CachePath)
    Assert-MonitorComponent -Component $Component
    $uri = [Uri]$Component.url
    $fileName = [IO.Path]::GetFileName($uri.AbsolutePath)
    $cacheRoot = [IO.Path]::GetFullPath($CachePath)
    Assert-MonitorArtifactPath -Path $cacheRoot
    $artifactPath = Join-Path $cacheRoot $fileName
    if (Test-Path -LiteralPath $artifactPath -PathType Leaf) {
        Assert-MonitorArtifactPath -Path $artifactPath
        Assert-MonitorArtifactHash -Path $artifactPath -ExpectedSha256 $Component.sha256
        return $artifactPath
    }
    if (-not $PSCmdlet.ShouldProcess($artifactPath, ('Download pinned ' + $Component.id + ' artifact and verify SHA-256'))) { return }
    $null = [IO.Directory]::CreateDirectory($cacheRoot)
    $partialPath = $artifactPath + '.partial-' + [Guid]::NewGuid().ToString('N')
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $uri.AbsoluteUri -OutFile $partialPath -UseBasicParsing -ErrorAction Stop
        Assert-MonitorArtifactHash -Path $partialPath -ExpectedSha256 $Component.sha256
        Move-Item -LiteralPath $partialPath -Destination $artifactPath -ErrorAction Stop
        return $artifactPath
    } catch {
        if (Test-Path -LiteralPath $partialPath) { Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue }
        throw ('Unable to acquire the verified ' + $Component.id + ' artifact. Check network access, cache contents and the pinned SHA-256.')
    }
}

function Expand-MonitorArtifact {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]$Component,
        [Parameter(Mandatory = $true)][string]$ArtifactPath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )
    Assert-MonitorComponent -Component $Component
    Assert-MonitorArtifactPath -Path $ArtifactPath
    Assert-MonitorArtifactHash -Path $ArtifactPath -ExpectedSha256 $Component.sha256
    $destination = [IO.Path]::GetFullPath($DestinationPath)
    Assert-MonitorArtifactPath -Path $destination
    if ((Test-Path -LiteralPath $destination) -and @(Get-ChildItem -LiteralPath $destination -Force).Count -gt 0) { throw 'Artifact extraction requires an empty dedicated destination.' }
    if (-not $PSCmdlet.ShouldProcess($destination, ('Extract verified ' + $Component.id + ' artifact'))) { return }
    $null = [IO.Directory]::CreateDirectory($destination)
    switch ($Component.archiveType) {
        'exe' {
            $executablePath = Join-Path $destination $Component.executableRelativePath
            $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $executablePath))
            Copy-Item -LiteralPath $ArtifactPath -Destination $executablePath -ErrorAction Stop
        }
        'zip' { Expand-MonitorZip -ArtifactPath $ArtifactPath -DestinationPath $destination }
        'tar.gz' { Expand-MonitorTar -ArtifactPath $ArtifactPath -DestinationPath $destination }
        default { throw 'Unsupported artifact archive type.' }
    }
    $executablePath = Join-Path $destination $Component.executableRelativePath
    if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) { throw ('Expected executable missing from normalized ' + $Component.id + ' artifact.') }
    Assert-MonitorArtifactPath -Path $executablePath
    return $destination
}

function Assert-MonitorArtifactHash {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$ExpectedSha256)
    if ($ExpectedSha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Expected SHA-256 must contain exactly 64 hexadecimal characters.' }
    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    if (-not $actualHash.Equals($ExpectedSha256, [StringComparison]::OrdinalIgnoreCase)) { throw 'Artifact SHA-256 verification failed; the file will not be executed or extracted.' }
}

function Assert-MonitorComponent {
    param($Component)
    foreach ($property in @('id', 'version', 'url', 'sha256', 'archiveType', 'executableRelativePath', 'license', 'serviceStrategy')) {
        if ($null -eq $Component.PSObject.Properties[$property] -or [string]::IsNullOrWhiteSpace([string]$Component.$property)) { throw 'Incomplete dependency manifest component.' }
    }
    if ($Component.id -notmatch '^[a-z][a-z0-9_]*$' -or $Component.version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw 'Unsafe dependency identifier or version.' }
    $uri = $null
    if (-not [Uri]::TryCreate($Component.url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.Host -notin @('github.com', 'dl.grafana.com') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw 'Dependencies must use pinned official HTTPS distribution URLs.' }
    if ($Component.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $Component.archiveType -notin @('exe', 'zip', 'tar.gz')) { throw 'Invalid dependency hash or archive type.' }
    $null = Get-MonitorArchiveRelativePath -Member $Component.executableRelativePath
}

function Assert-MonitorArtifactPath {
    param([string]$Path)
    $cursor = [IO.Path]::GetFullPath($Path)
    if ($cursor.TrimEnd('\', '/') -eq [IO.Path]::GetPathRoot($cursor).TrimEnd('\', '/')) { throw 'A dedicated artifact path is required; drive roots are not allowed.' }
    while ($cursor) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Artifact paths cannot contain reparse points.' }
        $parent = Split-Path -Parent $cursor
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Get-MonitorArchiveRelativePath {
    param([string]$Member)
    $normalized = $Member.Replace('\', '/').TrimEnd('/')
    if (-not $normalized -or $normalized -match '^[\/]' -or $normalized -match '[:\x00-\x1f]' -or $normalized.Split('/') -contains '..' -or $normalized.Split('/') -contains '.') { throw 'Unsafe archive member path.' }
    foreach ($segment in $normalized.Split('/')) {
        if (-not $segment -or $segment.EndsWith('.') -or $segment.EndsWith(' ') -or $segment -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { throw 'Unsupported Windows archive member path.' }
    }
    return $normalized
}

function Expand-MonitorZip {
    param([string]$ArtifactPath, [string]$DestinationPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArtifactPath)
    try {
        $members = @($archive.Entries | Where-Object { $_.FullName.TrimEnd('/') } | ForEach-Object { Get-MonitorArchiveRelativePath -Member $_.FullName })
        $topNames = @($members | ForEach-Object { ($_ -split '/')[0] } | Select-Object -Unique)
        if ($topNames.Count -ne 1 -or @($members | Where-Object { $_ -match '/' }).Count -eq 0) { throw 'Expected exactly one archive top-level directory.' }
        foreach ($entry in $archive.Entries) {
            if (-not $entry.FullName.TrimEnd('/')) { continue }
            $member = Get-MonitorArchiveRelativePath -Member $entry.FullName
            if ((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'Symbolic links are not supported in dependency archives.' }
            if ($member -eq $topNames[0]) { continue }
            $relative = $member.Substring($topNames[0].Length + 1)
            $target = [IO.Path]::GetFullPath((Join-Path $DestinationPath $relative))
            if (-not $target.StartsWith($DestinationPath.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Archive member escapes its destination.' }
            if ($entry.FullName.EndsWith('/')) { $null = [IO.Directory]::CreateDirectory($target); continue }
            $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $target))
            $source = $entry.Open()
            try {
                $output = New-Object IO.FileStream($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
                try { $source.CopyTo($output) } finally { $output.Dispose() }
            } finally { $source.Dispose() }
        }
    } finally { $archive.Dispose() }
}

function Expand-MonitorTar {
    param([string]$ArtifactPath, [string]$DestinationPath)
    $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if (-not $tar) { throw 'Windows tar.exe is required to extract the pinned Grafana archive.' }
    $listing = @(& $tar.Source -tzf $ArtifactPath 2>$null)
    if ($LASTEXITCODE -ne 0 -or $listing.Count -eq 0) { throw 'Unable to inspect dependency tar archive.' }
    $members = @($listing | ForEach-Object { Get-MonitorArchiveRelativePath -Member ([string]$_) })
    $topNames = @($members | ForEach-Object { ($_ -split '/')[0] } | Select-Object -Unique)
    if ($topNames.Count -ne 1 -or @($members | Where-Object { $_ -match '/' }).Count -eq 0) { throw 'Expected exactly one tar archive top-level directory.' }
    $types = @(& $tar.Source -tvzf $ArtifactPath 2>$null)
    if ($LASTEXITCODE -ne 0 -or @($types | Where-Object { $_ -notmatch '^[-d]' }).Count -gt 0) { throw 'Only regular files and directories are supported in dependency tar archives.' }
    & $tar.Source -xzf $ArtifactPath --strip-components 1 -C $DestinationPath 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Dependency tar extraction failed.' }
    foreach ($item in Get-ChildItem -LiteralPath $DestinationPath -Recurse -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Extracted artifact contains a reparse point.' }
    }
}

Export-ModuleMember -Function Read-MonitorManifest, Get-MonitorArtifact, Expand-MonitorArtifact, Assert-MonitorArtifactHash
