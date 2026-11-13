# Metrics contract v1

Candidate pin: windows_exporter **0.32.1**, Prometheus **3.16.0**. The exporter executable SHA-256 is `da0e3d3bd45a32feed3ae966225a2892cf3fdbc0918cf6ea4971befa17295dea`. Validate against `config/dependencies.lock.json` before execution. Source: [official tagged release](https://github.com/prometheus-community/windows_exporter/releases/tag/v0.32.1).

## Identity and configuration

The local target uses `job="windows_exporter", instance="local"`; Prometheus self-monitoring uses `job="prometheus", instance="local"`. No machine hostname is required. Grafana's Prometheus datasource UID is `pc-monitor-prometheus`. Rule names and label sets below are the stable dashboard interface; raw exporter names are pinned dependencies rather than a universal compatibility promise.

Exporter configuration renders to `exporters/windows_exporter.yml` with `--config.file=<absolute-path>`. Its template uses `{{EXPORTER_PORT}}`, `{{PROCESS_INCLUDE_YAML}}`, and `{{PROCESS_EXCLUDE_YAML}}`; the latter two must be YAML-quoted scalars, not raw interpolation. Process filters are case-sensitive regular expressions applied before collection. Defaults include all names and exclude none; recording rules separately omit Idle and _Total. Collection includes cpu, memory, logical_disk, physical_disk, net, os, system, process, service. [Configuration source](https://github.com/prometheus-community/windows_exporter/blob/v0.32.1/README.md#using-a-configuration-file).

The exporter uses Go regular-expression syntax. PowerShell/.NET regex validation is only a preliminary sanity check: lookbehind accepted by .NET was rejected by the pinned exporter with exit code 1. Before service mutations, preflight the rendered config with the checksum-verified exporter using `--config.file=<path> --scrape.stdout`; discard or sanitize the output before logging because it contains the raw info families described below. No dedicated config-check flag was found in this pin's help.

## Privacy boundary

Set process `cmdline: false` (CLI equivalent `--no-collector.process.cmdline`) because this version enables command-line labels by default. Disable network `nic_info` by setting `collector.net.enabled: metrics`. Prometheus must drop `windows_process_info` and `windows_service_info` completely, since these may expose owner, executable paths or service arguments. Also drop hostname, NIC information and logical-disk information families from the core dataset. Do not export the loopback endpoint through Cloudflare. Dropping series at scrape prevents persistence, not their existence on the exporter endpoint. [Process documentation](https://github.com/prometheus-community/windows_exporter/blob/v0.32.1/docs/collector.process.md), [service documentation](https://github.com/prometheus-community/windows_exporter/blob/v0.32.1/docs/collector.service.md), [network documentation](https://github.com/prometheus-community/windows_exporter/blob/v0.32.1/docs/collector.net.md).

## Recording interface

| Recording name | Unit | Labels beyond job/instance | Meaning |
|---|---|---|---|
| `pc_monitor:cpu_logical_processors:count` | count | none | Number of idle-mode CPU series |
| `pc_monitor:cpu_usage:ratio` | 0–1 | none | Average scheduled CPU time excluding idle |
| `pc_monitor:memory_used:ratio` | 0–1 | none | One minus available / physical total |
| `pc_monitor:memory_used:bytes` | bytes | none | Physical total minus available |
| `pc_monitor:process_cpu_usage:cores` | core equivalents | process, process_id | Sum of process user/privileged CPU seconds per second |
| `pc_monitor:process_cpu_usage:ratio` | 0–1 host capacity | process, process_id | Process core equivalents / host logical processors |
| `pc_monitor:volume_free:ratio` | 0–1 | volume | Free volume bytes / total volume bytes |
| `pc_monitor:network_receive:bytes_per_second` | bytes/s | nic | Received byte counter rate |
| `pc_monitor:network_transmit:bytes_per_second` | bytes/s | nic | Sent byte counter rate |

Rules live in `config/recording-rules/core.yml` and use a two-minute rate window. Core configuration accepts a scrape interval of 5–30 seconds, default 15 seconds; longer intervals need a separate rate-window design. Rate panels require at least two samples; a fresh installation must show warm-up/no data, not invented zeros. Multiply ratios by 100 only for percent-number presentation; Grafana percentunit formatting consumes 0–1 values directly.

CPU-time utilization is intentionally a scheduling-time measure. Task Manager may use frequency-adjusted processor utility, so exact agreement is not promised. The accuracy gate must compare matching time windows and explain this distinction. [Tagged CPU documentation](https://github.com/prometheus-community/windows_exporter/blob/v0.32.1/docs/collector.cpu.md).

## Process identity limitations

PID and name are not permanent identity. The start timestamp `windows_process_start_time_seconds_timestamp` is retained, and CPU rates are suppressed when its value changes in the two-minute window. This guards observed same-name/PID reuse but does not create an immutable identity label. Drilldown must show the start timestamp; long-range per-PID memory growth is not a trustworthy leak diagnosis across restarts. Start-time guards cannot recover processes entirely missed between scrapes. Do not add start timestamp labels or custom enrichment without a separate cardinality review.

Top-N is a query/presentation control, not an ingestion limit. Process include/exclude filters must be configurable. The 50,000 sample per-scrape ceiling makes excess visible as a scrape failure rather than silently accepting unlimited data, but does not cap historical PID churn. `doctor` must surface active series and storage; filtering may miss workloads and must be visible to the user.

## Availability and validation state

`up` is target reachability; `windows_exporter_collector_success{collector=...}` distinguishes partial collector failure. Missing optional hardware telemetry is unsupported until a capability baseline is established; disappearance of previously expected data is a different condition. No `or vector(0)` fallback is allowed for health or sensor panels.

On 2026-11-13 a checksum-verified, non-elevated, temporary exporter on `127.0.0.1:19182` exposed real core metrics with all nine collector success flags equal to 1. Command-line labels were empty and NIC address information absent. The owned process was terminated in `finally`; real metrics/logs remain only under ignored `artifacts/local/`. This verifies portable collection, not service accounts, SCM startup, reboot survival, hardware sensors, Grafana rendering or email.

Tracked fixtures must be synthetic with names such as `example_app` and `Example NIC`, not copied host inventory. They represent the tagged metric schema. Full Prometheus query behavior and process CPU semantics require promtool fixtures plus live query tests; acceptance must record the exact tested versions and limitations.

Additional checks on 2026-11-13: rendered exporter YAML with `--scrape.stdout` exited 0 with all nine collectors succeeding. Prometheus archive SHA-256 matched the lock; `promtool check config`, `promtool check rules`, and `promtool test rules tests/prometheus/core.test.yml` exited 0. A separate synthetic two-core/one-core-process case produced the expected 0.5 host fraction, using floating-point comparison tolerance. The live Prometheus scrape attempt was blocked by Windows Application Control when starting `prometheus.exe`, including one sandbox-escalated retry; both attempts cleaned up their owned exporter process. No policy changes or bypasses were attempted. Thus actual Prometheus ingestion remains **BLOCKED**, while config/recording syntax and synthetic formulas passed.
