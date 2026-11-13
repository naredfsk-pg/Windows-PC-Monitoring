Set-StrictMode -Version Latest

function Get-MonitorSecretPath {
    param([string]$Name, [string]$DataRoot)
    $fileName = switch ($Name) {
        'GrafanaAdminPassword' { 'grafana-admin-password' }
        'SmtpPassword' { 'smtp-password' }
        default { throw 'Unknown secret name. Use GrafanaAdminPassword or SmtpPassword.' }
    }
    if (-not [IO.Path]::IsPathRooted($DataRoot)) { throw 'DataRoot must be an absolute path.' }
    return Join-Path (Join-Path ([IO.Path]::GetFullPath($DataRoot)) 'secrets') $fileName
}

function Assert-MonitorSecretLocation {
    param([string]$Path)
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Secrets paths cannot contain reparse points.'
            }
        }
        $parent = Split-Path -Parent $cursor
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Assert-MonitorSecretAcl {
    param([string]$Path, [switch]$Directory)
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    if (-not $acl.AreAccessRulesProtected) { throw 'Existing secret store has inherited permissions; refusing to use it.' }
    $required = @{ 'S-1-5-18' = $false; 'S-1-5-32-544' = $false; 'S-1-5-19' = $false }
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        $sid = $rule.IdentityReference.Value
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or -not $required.ContainsKey($sid)) {
            throw 'Existing secret store has unexpected permissions; refusing to use it.'
        }
        $rights = [int]$rule.FileSystemRights
        if ($sid -eq 'S-1-5-19') {
            $allowed = [int][Security.AccessControl.FileSystemRights]::Read -bor [int][Security.AccessControl.FileSystemRights]::Synchronize
            if ($Directory) { $allowed = [int][Security.AccessControl.FileSystemRights]::ReadAndExecute -bor [int][Security.AccessControl.FileSystemRights]::Synchronize }
            if (($rights -band (-bnot $allowed)) -ne 0) { throw 'LocalService has excessive secret permissions; refusing to use the store.' }
            if (($rights -band [int][Security.AccessControl.FileSystemRights]::Read) -eq [int][Security.AccessControl.FileSystemRights]::Read) { $required[$sid] = $true }
        } elseif (($rights -band [int][Security.AccessControl.FileSystemRights]::FullControl) -eq [int][Security.AccessControl.FileSystemRights]::FullControl) {
            $required[$sid] = $true
        }
    }
    if (@($required.Values | Where-Object { -not $_ }).Count -gt 0) { throw 'Existing secret store lacks required service/administrator permissions.' }
}

function Set-MonitorSecret {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][Security.SecureString]$Value,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [switch]$Replace
    )
    $path = Get-MonitorSecretPath -Name $Name -DataRoot $DataRoot
    if ((Test-Path -LiteralPath $path) -and -not $Replace) { throw 'Secret already exists. Explicit rotation requires -Replace.' }
    if (-not $PSCmdlet.ShouldProcess($path, 'Store secret with Windows ACL protection')) { return }
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Secret provisioning requires an elevated Administrator session.' }
    Assert-MonitorSecretLocation -Path $path
    $directory = Split-Path -Parent $path
    $null = [IO.Directory]::CreateDirectory($directory)
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($entry in @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'), @('S-1-5-19', 'ReadAndExecute'))) {
        $sid = New-Object Security.Principal.SecurityIdentifier($entry[0])
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, $entry[1], 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $directory -AclObject $acl -ErrorAction Stop
    $fileAcl = New-Object Security.AccessControl.FileSecurity
    $fileAcl.SetAccessRuleProtection($true, $false)
    foreach ($entry in @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'), @('S-1-5-19', 'Read'))) {
        $sid = New-Object Security.Principal.SecurityIdentifier($entry[0])
        $fileAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, $entry[1], 'Allow')))
    }
    # Protect an existing file before rotating its content; new files inherit the restricted directory ACL.
    if (Test-Path -LiteralPath $path) { Set-Acl -LiteralPath $path -AclObject $fileAcl -ErrorAction Stop }
    $pointer = [IntPtr]::Zero
    $temporaryPath = Join-Path $directory ('.pending-' + [Guid]::NewGuid().ToString('N'))
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
        $plaintext = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        if ([string]::IsNullOrWhiteSpace($plaintext) -or $plaintext -match '[\r\n\x00]') { throw 'Secret must be nonempty and contain no newlines or NUL.' }
        [IO.File]::WriteAllText($temporaryPath, $plaintext, (New-Object Text.UTF8Encoding($false)))
        Set-Acl -LiteralPath $temporaryPath -AclObject $fileAcl -ErrorAction Stop
        Assert-MonitorSecretAcl -Path $temporaryPath
        if (Test-Path -LiteralPath $path) {
            if (-not $Replace) { throw 'Secret was provisioned by another operation; refusing to replace it.' }
            [IO.File]::Replace($temporaryPath, $path, $null)
        } else { [IO.File]::Move($temporaryPath, $path) }
        Assert-MonitorSecretAcl -Path $directory -Directory
        Assert-MonitorSecretAcl -Path $path
    } finally {
        $plaintext = $null
        if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
    }
}

function Get-MonitorSecret {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$DataRoot)
    $path = Get-MonitorSecretPath -Name $Name -DataRoot $DataRoot
    Assert-MonitorSecretLocation -Path $path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Requested secret has not been provisioned.' }
    Assert-MonitorSecretAcl -Path (Split-Path -Parent $path) -Directory
    Assert-MonitorSecretAcl -Path $path
    try { return ConvertTo-SecureString -String ([IO.File]::ReadAllText($path)) -AsPlainText -Force } catch { throw 'Unable to read protected secret; check the service identity and ACL.' }
}

Export-ModuleMember -Function Get-MonitorSecretPath, Get-MonitorSecret, Set-MonitorSecret
