# Troubleshooting

## Prometheus is blocked before installation

The installer preflights pinned binaries before it changes services or protected directories. If it reports that `prometheus.exe` was blocked, inspect **Event Viewer → Applications and Services Logs → Microsoft → Windows → CodeIntegrity → Operational**. Event ID 3077 means an enforced App Control policy blocked a file; it is not an installer or Cloudflare failure.

For policy ID `{0283AC0F-FFF1-49AE-ADA1-8A933130CAD6}`, the blocker is Windows Smart App Control. It has no per-app/hash exception. `Unblock-File`, PowerShell execution-policy changes, folder exclusions and a self-signed certificate do not provide a supported resolution.

Use a provenance-verified build signed by a certificate trusted through Microsoft's Trusted Root Program, or make an explicit device-wide decision to turn Smart App Control off in Windows Security. The project never changes this setting automatically. The SHA-256 in `config/dependencies.lock.json` verifies the downloaded archive and must not be described as a Smart App Control allow rule.

## No owned installation metadata

`start.ps1`, `stop.ps1`, `backup.ps1`, `restore.ps1`, and `uninstall.ps1` refuse to operate when `DataRoot/installation.json` is missing or does not prove ownership of the service paths. This protects unrelated services and data. Use `install.ps1 -WhatIf -AsJson` to inspect the planned roots and service names.

## Collector or dashboard data is unavailable

Run `doctor.ps1 -AsJson` after a completed local installation. It separately checks the service identity, loopback readiness, Prometheus exporter target, each of the nine required collector success metrics, and their freshness. A target reported as UP is insufficient when an individual required collector failed.

Hardware sensors and SMART are not part of the core profile. They appear as unsupported rather than as zero or healthy values until the optional hardware phase is installed and verified.
