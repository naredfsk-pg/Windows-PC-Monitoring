function Invoke-QACase {
    param([System.Collections.Generic.List[object]]$Results, [string]$Name, [scriptblock]$Action)
    try {
        & $Action | Out-Host
        $Results.Add([pscustomobject]@{ Status = 'PASS'; Name = $Name; Detail = '' })
    } catch {
        $Results.Add([pscustomobject]@{ Status = 'FAIL'; Name = $Name; Detail = ' - ' + $_.Exception.Message })
    }
}

function Assert-QATrue {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-QAThrows {
    param([scriptblock]$Action, [string]$Message)
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    if (-not $threw) { throw $Message }
}

function New-QATemporaryDirectory {
    $path = Join-Path ([IO.Path]::GetTempPath()) ('PCMonitor-QA-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($path) | Out-Null
    return $path
}

function Remove-QATemporaryDirectory {
    param([string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char]'\')
    if (-not $fullPath.StartsWith($parent + '\', [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($fullPath) -notmatch '^PCMonitor-QA-[0-9a-f]{32}$') {
        throw 'Refusing cleanup outside the owned temporary test directory.'
    }
    if (-not [IO.Directory]::Exists($fullPath)) { return }
    $pending = New-Object System.Collections.Generic.Stack[string]
    $pending.Push($fullPath)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($child in [IO.Directory]::EnumerateDirectories($directory)) {
            if (([IO.File]::GetAttributes($child) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                [IO.Directory]::Delete($child)
            } else { $pending.Push($child) }
        }
    }
    [IO.Directory]::Delete($fullPath, $true)
}

function Complete-QACases {
    param([System.Collections.Generic.List[object]]$Results, [string]$Suite)
    foreach ($result in $Results) { Write-Output ('{0}: {1}{2}' -f $result.Status, $result.Name, $result.Detail) }
    $failures = @($Results | Where-Object Status -eq 'FAIL').Count
    $skips = @($Results | Where-Object Status -eq 'SKIPPED').Count
    Write-Output ('{0}: cases={1}; failed={2}; skipped={3}.' -f $Suite, $Results.Count, $failures, $skips)
    if ($failures -gt 0) { throw ($Suite + ' failed: ' + $failures) }
}
