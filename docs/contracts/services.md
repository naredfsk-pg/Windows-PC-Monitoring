# Windows service contract v1

WinSW 2.12.0 NET461 is the selected SCM host for the three console binaries. This is a design backed by tagged upstream documentation; target-host service startup, permissions, graceful shutdown and reboot recovery remain required runtime gates. Do not register ordinary console binaries directly with `New-Service` and assume they implement the SCM protocol.

## Names and paths

| Component | Stable service name | Process account | Listener |
|---|---|---|---|
| windows_exporter | `PCMonitor-Exporter` | LocalSystem in the initial privileged-collector profile | `127.0.0.1:9182` by default |
| Prometheus | `PCMonitor-Prometheus` | `NT AUTHORITY\LocalService` | `127.0.0.1:9090` by default |
| Grafana | `PCMonitor-Grafana` | `NT AUTHORITY\LocalService` | `127.0.0.1:3000` by default |

Exporter LocalSystem is a disclosed initial compatibility exception for Windows process/service/performance counter access, not a claim that every collector requires it. A3's non-elevated process smoke demonstrates available counters in one interactive user context, not LocalService access. Do not silently grant privileges or change security policy to make a collector work. A least-privilege exporter profile requires its own service-account smoke and documented missing-collector behavior.

Use `InstallRoot\<component>\<version>\` for normalized binaries. Keep WinSW instance EXE and same-basename XML together under `InstallRoot\services\`, named after the stable service. Example: `PCMonitor-Prometheus.exe` and `PCMonitor-Prometheus.xml`. Quote all paths inside XML arguments and XML-escape values; never build a shell command from a configuration string.

Mutable state is separated:

```text
DataRoot/config/                  generated component configuration
DataRoot/data/prometheus/         Prometheus TSDB/WAL
DataRoot/data/grafana/            Grafana DB and mutable plugin state
DataRoot/logs/<component>/        component and wrapper diagnostics
DataRoot/secrets/                 protected named files
DataRoot/installation.json        ownership/version/path metadata, no credentials
```

`installation.json` is written only after a successful installation transaction and records schema version, owned services, install/data roots and exact manifest versions/hashes. Existing services must be checked against this metadata and their executable path before mutation; matching a service name alone does not prove ownership. Missing or conflicting ownership evidence requires explicit operator resolution.

## SCM behavior

Automatic startup, restart after failure (10 seconds initial retry, 30 seconds later retries), rolling logs, and a 60-second graceful stop timeout are the initial settings. Use WinSW's documented install/start/stop/uninstall interface with absolute paths. No reboot failure action is permitted. Prometheus uses its own shutdown handling; do not enable admin/lifecycle web APIs merely to stop it.

Start in order Exporter → Prometheus → Grafana and stop in reverse. Readiness is checked with bounded retries; process/service Running is not a successful scrape or a usable dashboard. Runtime retry handles absent metrics and transient startup/network failures. Avoid hard SCM dependency coupling that permanently stops otherwise useful local components when an exporter fails; alert on unavailable telemetry instead.

Before installation verify architecture, OS build, required .NET Framework, free ports and binary hashes. `WhatIf` emits a complete plan but does not elevate, download, write credentials/configuration, install services, or alter ACLs. Actual host changes require Administrator privileges and authorization. Do not silently elevate from a read-only command.

Core installation never changes the existing `cloudflared` service, firewall, DNS, Cloudflare Access policy, power policy, Windows Update or registry configuration. Reading registry values for OS/.NET detection is permitted; modifying them is not part of this contract.

## ACL model

| Path | Administrators / SYSTEM | LocalService | Ordinary users |
|---|---|---|---|
| InstallRoot binaries/service XML | FullControl | ReadAndExecute | No write |
| DataRoot root / config | FullControl | ReadAndExecute | No write |
| Prometheus/Grafana data + their logs | FullControl | Modify | No access by default |
| secrets directory/files | FullControl | Read / required directory traversal | No access |
| installation metadata | FullControl | Read | No write |

Apply ACLs before writing secrets or launching a service. For paths outside the defaults, validate the resolved path and reject repository paths, drive roots, reparse points and overlapping install/data roots. Do not recursively rewrite ACLs on an existing unrelated directory. Accounts are built-in identities identified by SID where possible, avoiding localized display-name assumptions.

The shared LocalService account means Prometheus and Grafana are not isolated from each other; the initial threat model does not claim containment between mutually trusted local monitoring services. Credentials must never be placed in service XML arguments or logs.

## Evidence needed before runtime acceptance

- Service installed under the intended identity and executable path; generated config and secret ACL checks.
- Real exporter scrape, Prometheus query and Grafana datasource/dashboard readiness.
- Controlled failure/restart and stop behavior without corrupting TSDB/Grafana DB.
- Reboot evidence showing all three services start and serve data before interactive login.
- Existing cloudflared and other host services remain unchanged.

Reference: [WinSW v2.12.0 XML configuration](https://github.com/winsw/winsw/blob/v2.12.0/doc/xmlConfigFile.md) documents LocalService, automatic startup, restart policy, stop timeout and wrapper operations.
