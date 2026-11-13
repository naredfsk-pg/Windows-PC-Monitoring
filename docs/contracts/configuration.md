# Configuration contract v1

This is the authoring interface frozen for the core implementation. Module behavior must be tested against this contract; contract freeze does not satisfy runtime acceptance.

## Input and precedence

Use a flat PowerShell data file (`.psd1`) loaded with `Import-PowerShellDataFile`, never `Invoke-Expression` or dot-sourcing. Merge built-in defaults, the optional `-Path` file, then the optional `-OverridePath` file. Validate the merged object and reject unknown keys. Do not implicitly discover `.env`, user profile scripts, the current directory's config, or machine environment overrides. The root `.env` currently contains an owner tunnel install command and is not an input to these APIs.

| Key | Type / default | Rules |
|---|---|---|
| Profile | string / `local` | `local` or `owner` |
| InstallRoot | string / `%ProgramFiles%\PCMonitor` | Fully qualified filesystem path; binaries/service wrappers only |
| DataRoot | string / `%ProgramData%\PCMonitor` | Fully qualified filesystem path; must not overlap InstallRoot |
| GrafanaPort | int / `3000` | 1024–65535, unique among the three ports |
| PrometheusPort | int / `9090` | 1024–65535 |
| ExporterPort | int / `9182` | 1024–65535 |
| ScrapeInterval | string / `15s` | Core supported range `5s` through `30s`, integer seconds only; fixed 2-minute query rate windows depend on this bound |
| RetentionTime | string / `30d` | Positive Prometheus duration |
| RetentionSize | string / `10GB` | Positive supported Prometheus size suffix |
| PublicHostname | string / empty | Empty for local; owner requires full DNS hostname, no scheme/path/wildcard/port |
| GrafanaUrl | string / `http://localhost:3000` | Local URL must match chosen GrafanaPort; owner URL must be HTTPS and match PublicHostname |
| Timezone | string / `browser` | `browser`, `utc`, or a validated IANA timezone such as `Asia/Bangkok` |
| ProcessInclude | string / `.+` | Exporter-supported inclusion expression; do not silently convert dialects |
| ProcessExclude | string / empty | Exporter-supported exclusion expression |

All listener addresses are fixed to `127.0.0.1` in v1; no user key can silently widen a listener. Set Prometheus `scrape_timeout` to the rendered ScrapeInterval so the 5-second minimum never conflicts with a longer default timeout. Reject NUL/newlines in scalar configuration, path roots/traversal values that could make lifecycle deletion unsafe, URI userinfo/query/fragment, duplicate ports, and invalid types rather than coercing arbitrary strings. Path validation must handle Windows case-insensitivity and trailing separators. External public hostname verification occurs at deployment; syntax validation alone does not prove DNS/ownership.

Changing GrafanaPort derives the matching local GrafanaUrl unless the input explicitly supplies GrafanaUrl; an explicit URL must match the final port. No owner hostname/email is a runtime default. Optional extension configuration will be added in a later contract revision; do not accept unused feature keys as if the feature worked. Core paths reject quotes, control characters, traversal segments, alternate data streams and trailing-dot/space aliases so template delimiters and Windows path aliases cannot alter configuration meaning.

## Public module APIs

`Read-MonitorConfig([string] Path, [string] OverridePath) -> [hashtable]`: read explicit files, merge and validate; throw a sanitized error if invalid. Both path parameters are optional. No host mutation.

`Test-MonitorConfig([System.Collections.IDictionary] Config) -> [pscustomobject]`: return `Valid` (Boolean) and `Errors` (string array). No output streams other than the result and no filesystem/network/service mutation.

`Write-MonitorConfiguration([System.Collections.IDictionary] Config, [string] OutputPath, [string] RepositoryRoot) -> generated path metadata`: RepositoryRoot is optional and defaults to the repository containing the module. Validate before writing; write only beneath OutputPath, preserve unrelated files, use UTF-8 without BOM and deterministic rendering. No secret reads/provisioning, downloads, service changes, mail, or cloud actions. The installer uses `DataRoot\config` as OutputPath; tests may use an isolated workspace directory.

Templates use the following exact tokens. Unknown or unresolved tokens fail closed; do not interpolate PowerShell expressions from template contents:

```text
{{EXPORTER_PORT}} {{PROMETHEUS_PORT}} {{GRAFANA_PORT}}
{{SCRAPE_INTERVAL}} {{RETENTION_TIME}} {{RETENTION_SIZE}}
{{GRAFANA_URL}} {{TIMEZONE}} {{GRAFANA_COOKIE_SECURE}}
{{PROMETHEUS_DATA_PATH}} {{GRAFANA_DATA_PATH}} {{GRAFANA_LOG_PATH}}
{{GRAFANA_PROVISIONING_PATH}} {{GRAFANA_ADMIN_SECRET_PATH}}
{{GRAFANA_DASHBOARDS_PATH}}
{{PROCESS_INCLUDE_YAML}} {{PROCESS_EXCLUDE_YAML}}
```

Render using format-appropriate escaping: use forward-slash Windows paths in YAML/INI where supported; serialize strings for YAML/JSON rather than trusting quote characters in a path. Output paths are resolved beneath the configured destination before writing. Process regex values must be escaped as data and never appended to executable shell code.

Generated layout:

```text
OutputPath/
  prometheus/prometheus.yml
  prometheus/rules/*.yml
  exporters/windows_exporter.yml
  grafana/grafana.ini
  grafana/provisioning/datasources/*.yml
  grafana/provisioning/dashboards/*.yml
  grafana/dashboards/*.json
```

Path tokens derive from DataRoot: `data/prometheus`, `data/grafana`, `logs/grafana`, `secrets/grafana-admin-password`; provisioning/dashboard tokens use the generated Grafana subtree. Empty optional template directories need not produce files.

Stable Grafana datasource UID is `pc-monitor-prometheus`. Dashboard UIDs are `pc-monitor-overview` and `pc-monitor-processes`. Prometheus jobs are `windows_exporter` and `prometheus`; instance/host label conventions belong to the metrics contract. Grafana-owned alerts are not duplicated as independently notifying Prometheus alerts. Regex input uses a limited RE2-compatible subset (maximum 512 characters; no lookarounds/backreferences; optional leading `(?i)`); the pinned exporter still performs final syntax preflight before service mutation.

## Secret module APIs

`Set-MonitorSecret([string] Name, [securestring] Value, [string] DataRoot)` supports ShouldProcess/WhatIf/Confirm and provisions only an explicitly named secret. `Get-MonitorSecret([string] Name, [string] DataRoot) -> [securestring]` returns a SecureString without printing its plaintext value. Names are whitelisted; `GrafanaAdminPassword` maps to `DataRoot\secrets\grafana-admin-password`, and future `SmtpPassword` maps to `smtp-password`. Never accept an arbitrary path as Name.

Store UTF-8-no-BOM secret content in files with inheritance disabled, Administrators/SYSTEM FullControl and LocalService Read. Protect parent directories before file creation and avoid any interval where a new secret is readable by ordinary users. Validate final ACLs and reject a reparse-point path or an existing insecure store rather than trusting it. Error messages may identify a secret name/path but not its value. An empty/whitespace secret is invalid.

Initial installation generates a random Grafana password from at least 32 cryptographic random bytes when absent, never a fixed admin/admin credential. The installer preserves an existing secret. The renderer writes `admin_password = $__file{<protected-path>}` in Grafana INI and never substitutes plaintext. The file provider trims whitespace; generate passwords without leading/trailing whitespace. A bootstrap file change does not reset a password already stored in Grafana's database.

ACL-protected files are a deliberate minimal service-usable store, not encrypted-at-rest storage. LocalService is a shared Windows identity, so other services with that identity may read a file granted to it; do not claim per-service isolation. A later dedicated service SID/account design requires a new tested ACL contract. No service password or tunnel token appears in a process argument generated by the core installer.
