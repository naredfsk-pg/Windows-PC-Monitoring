# Core metric reference

Supported collection contract: [metrics v1](contracts/metrics.md). Current candidates are windows_exporter 0.32.1 and Prometheus 3.16.0. These names were checked against the pinned exporter, rather than copied from older dashboards.

| Area | Raw metric / expression | Unit / distinction |
|---|---|---|
| CPU | `windows_cpu_time_seconds_total{mode="idle"}` | Counter seconds per logical core; `1-avg(rate(...[2m]))` is scheduled-time utilization |
| RAM available | `windows_memory_available_bytes` | Bytes available to new allocations, including reclaimable cached memory |
| RAM total | `windows_memory_physical_total_bytes` | Physical capacity in bytes; do not use an obsolete os/cs total-memory metric |
| Commit | `windows_memory_committed_bytes`, `windows_memory_commit_limit_bytes` | Committed virtual memory and its limit, not physical working set |
| Process CPU | `windows_process_cpu_time_seconds_total` | Sum privileged/user rates, then divide by logical CPU count for host fraction |
| Process RAM | `windows_process_working_set_bytes` | Resident working set; shared pages can be counted in several processes |
| Process private RAM | `windows_process_working_set_private_bytes` | Resident pages private to a process |
| Process private allocation | `windows_process_private_bytes` | Private committed allocation, not necessarily resident |
| Process start | `windows_process_start_time_seconds_timestamp` | Epoch seconds; guards observed PID reuse and explains drilldown identity |
| Volume | `windows_logical_disk_free_bytes`, `windows_logical_disk_size_bytes` | Capacity in bytes labelled by volume |
| Disk throughput | `rate(windows_physical_disk_read_bytes_total[2m])` / write equivalent | Bytes/s by disk; does not establish SSD health or correct physical-to-volume mapping |
| Network | `rate(windows_net_bytes_received_total[2m])` / sent equivalent | Bytes/s by adapter `nic`, not bits/s |
| Uptime | `time()-windows_system_boot_time_timestamp` | Seconds since boot; follows system clock corrections |
| Service state | `windows_service_state{state="running"}` | 1 running / 0 otherwise, label key is `service` in this pin |
| Collection | `up{job="windows_exporter"}`, `windows_exporter_collector_success` | Target and per-collector health respectively |

CPU/process sources: [CPU](https://github.com/prometheus-community/windows_exporter/blob/v0.32.1/docs/collector.cpu.md), [process](https://github.com/prometheus-community/windows_exporter/blob/v0.32.1/docs/collector.process.md). Memory sources: [collector](https://github.com/prometheus-community/windows_exporter/blob/v0.32.1/docs/collector.memory.md), [physical-total implementation](https://github.com/prometheus-community/windows_exporter/blob/v0.32.1/internal/collector/memory/memory.go). Storage/network/system sources: [logical disk](https://github.com/prometheus-community/windows_exporter/blob/v0.32.1/docs/collector.logical_disk.md), [physical disk](https://github.com/prometheus-community/windows_exporter/blob/v0.32.1/docs/collector.physical_disk.md), [network](https://github.com/prometheus-community/windows_exporter/blob/v0.32.1/docs/collector.net.md), [system](https://github.com/prometheus-community/windows_exporter/blob/v0.32.1/docs/collector.system.md), [services](https://github.com/prometheus-community/windows_exporter/blob/v0.32.1/docs/collector.service.md).

Process and host percentages use 100% for all logical CPU capacity. One fully occupied thread on a 12-thread machine is about 8.33% host capacity, or one core equivalent. Frequency-adjusted Task Manager utilization may differ; it is not a direct comparison to scheduled CPU time.

`config/recording-rules/core.yml` defines the stable `pc_monitor:*` recording interface. Aggregating resident working sets by application name can double-count shared pages. Short-lived processes may not appear. Per-PID historical charts can span reused PIDs; use the start timestamp and avoid interpreting a long-term slope as a definitive memory leak.

The core dataset deliberately excludes sensitive info families. Sensors/GPU/SMART are not yet collected; absence means not collected or unsupported, never healthy. Initial recording-rate charts need two samples and a warm-up period. No hardware/temperature values are fabricated.

Prometheus time retention and size retention are independent limits. A size limit can remove old blocks before 30 days; WAL/head/compaction space means it is not a hard cap on the entire data directory. Monitor both TSDB size and the drive's free space.
