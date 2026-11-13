# Core architecture

Contract version: 1. Research date: 2026-11-13. Implementation and runtime status are recorded separately in the execution record; this document is not a claim that installation, reboot recovery, or alert delivery has passed.

## Components and responsibility

`windows_exporter` collects Windows counters. Prometheus scrapes the exporter on loopback and stores history. Grafana queries Prometheus and owns dashboards and eventual unified alerting. PowerShell only validates configuration, fetches pinned artifacts, renders provisioning, manages installation, and reports diagnostics. No custom web server or UI is required.

All core listeners are fixed to `127.0.0.1`. Changing the public Grafana URL does not change a listener address. The default profile is `local`; no Cloudflare account, public domain, SMTP account, heartbeat URL, or owner's identity is required to use local monitoring.

Cloudflare Tunnel is an optional independent connector to Grafana only. An existing `cloudflared` service is not owned by the core installer, and must not be reconfigured, replaced, stopped, or uninstalled by it. The user has separately installed the PC Monitor connector, but that does not authorize routing changes or establish Grafana availability.

Offline notification requires an external receiver because the local stack cannot evaluate or send an email while the machine is off. Sensor collection and SMART remain optional capability-driven extensions.

## Dependency direction

```text
User .psd1 data -> Config validation -> effective non-secret configuration
                                  -> template rendering -> component configuration
Protected secret files ---------------------------------> Grafana file provider
Pinned dependency manifest -> verified downloads -> installed versioned binaries
Effective configuration + installed binaries -> WinSW service definitions
Windows counters -> windows_exporter -> Prometheus -> Grafana
```

Config validation is pure apart from reading explicitly selected data files. Rendering may write only its specified output directory and must not fetch binaries, provision secrets, install services, send mail, or modify cloud settings. Artifact acquisition and service mutation remain separate module boundaries.

## Contracts and ownership

- [Configuration](contracts/configuration.md): input keys, precedence, module APIs, generated layout and rendering tokens.
- [Services](contracts/services.md): stable names, account/ACL model, WinSW invocation and ownership checks.
- [Operations](contracts/operations.md): installation transaction, diagnostics, backup/restore and evidence.
- Metrics and query contracts are owned by A3 and must use the pinned exporter version rather than names from an unrelated dashboard.
- [Dependency evidence](DEPENDENCIES.md) and the [dependency lock](../config/dependencies.lock.json) describe candidate artifacts and their provenance.

Contracts can be frozen for authoring when upstream behavior is documented and interfaces are explicit. This does not mark the Windows service smoke/reboot gate as passed. Consumers may implement against that design contract; runtime-dependent milestone acceptance remains pending until the approved host tests run. A failed smoke test requires reopening the contract and retesting affected consumers.

## Scope and limitations

Core authored deliverables cover Windows system/process collection, localhost dashboards and lifecycle scripts. SMTP firing/resolved delivery is a separate MVP gate. Hardware coverage, real service identity permissions, performance budget, fresh-machine installation, unattended reboot, and Cloudflare Access denial require direct evidence on the target environment.

The intended runtime is x64 Windows 10/11 with Windows PowerShell 5.1. This is the project's target matrix, not a certification that every upstream release supports every Windows build. The installer must reject unsupported architecture and report untested OS builds; dependency/platform smoke tests must be recorded before release.
