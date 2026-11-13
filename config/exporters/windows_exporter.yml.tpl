# windows_exporter v0.32.1; rendered input, never a Windows service installer.
web:
  listen-address: '127.0.0.1:{{EXPORTER_PORT}}'
collectors:
  enabled: cpu,memory,logical_disk,physical_disk,net,os,system,process,service
collector:
  process:
    include: {{PROCESS_INCLUDE_YAML}}
    exclude: {{PROCESS_EXCLUDE_YAML}}
    cmdline: false
  net:
    enabled: metrics
log:
  level: warn
