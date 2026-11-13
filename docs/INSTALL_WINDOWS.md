# Install on Windows

## Before installation

Run the repository checks and the non-mutating plan first:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Checks.ps1 -Stage Core
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1 -WhatIf -AsJson
```

The plan uses loopback-only endpoints: Grafana `127.0.0.1:3000`, Prometheus `127.0.0.1:9090`, and windows_exporter `127.0.0.1:9182`. It neither downloads software nor changes services, ACLs, firewall settings, Cloudflare, or DNS.

Review the manifest and its hashes in `config/dependencies.lock.json`. The default installation needs Windows x64, .NET Framework 4.6.1 or later for WinSW, `tar.exe` for the Grafana archive, unused loopback ports, and an Administrator session for the apply step.

## Application Control prerequisite

This host currently enforces the inbox Smart App Control policy `VerifiedAndReputableDesktop` (policy ID `{0283AC0F-FFF1-49AE-ADA1-8A933130CAD6}`), which blocks the pinned unsigned Prometheus executable. Smart App Control has no per-app, path or hash exception. The SHA-256 in the dependency lock verifies the downloaded ZIP; it is not an exception that can be added to Smart App Control.

The security-preserving resolution is an Authenticode-signed Prometheus build whose certificate chains to a CA in Microsoft's Trusted Root Program, with its provenance and artifact hash audited before pinning. Do not self-sign the upstream executable and claim Smart App Control compatibility.

If no trusted signed build is available, the owner must choose whether to turn Smart App Control off for the whole device from **Windows Security → App & browser control → Smart App Control settings → Off**. This lowers device-wide protection and is not performed by this installer. Microsoft currently documents that recent Windows updates can allow Smart App Control to be enabled again, but availability depends on the device state/build; verify the UI before assuming reversibility.

Windows event ID 3077 is an enforced block. See Microsoft's [inbox policy reference](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/windows-defender-application-control/operations/inbox-wdac-policies), [Smart App Control FAQ](https://support.microsoft.com/en-gb/windows/security/threat-malware-protection/smart-app-control-frequently-asked-questions), and [event reference](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/app-control-for-business/operations/event-id-explanations).

After selecting one of those supported resolutions, rerun the portable binary preflight before authorizing service installation. Do not treat a running `cloudflared` service as permission to run monitoring binaries.

## Apply after approval

Only after the pinned binaries pass Smart App Control and after reviewing the plan and obtaining authorization for host changes, open an elevated PowerShell session. Supply an admin password through a `SecureString` prompt so it is not written to disk or command history:

```powershell
$password = Read-Host 'Grafana admin password' -AsSecureString
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1 -Apply -GrafanaAdminPassword $password
```

The installer verifies download hashes and binary execution before it creates PC Monitor directories, ACLs, credentials, or Windows services. It does not modify the separately installed `cloudflared` service. On a policy or binary preflight failure, fix the approved policy path first and do not retry with a modified or unverified binary.

After a successful local installation, validate `http://localhost:3000` and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\doctor.ps1
```

Service reboot, SMTP, hardware sensor, external heartbeat, and Cloudflare-route tests remain separate acceptance gates.
