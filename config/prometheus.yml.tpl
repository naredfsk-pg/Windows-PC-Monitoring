global:
  scrape_interval: {{SCRAPE_INTERVAL}}
  evaluation_interval: {{SCRAPE_INTERVAL}}
  scrape_timeout: {{SCRAPE_INTERVAL}}

rule_files:
  - 'rules/*.yml'

scrape_configs:
  - job_name: windows_exporter
    sample_limit: 50000
    static_configs:
      - targets: ['127.0.0.1:{{EXPORTER_PORT}}']
        labels:
          instance: local
    metric_relabel_configs:
      # Do not persist process/service arguments, usernames, addresses or serials.
      - source_labels: [__name__]
        regex: 'windows_(process_info|service_info|os_hostname|logical_disk_info|net_nic_(address_)?info)'
        action: drop
      - regex: 'cmdline|command_line|owner|username|path_name|run_as|address|mac|serial_number|volume_name'
        action: labeldrop

  - job_name: prometheus
    static_configs:
      - targets: ['127.0.0.1:{{PROMETHEUS_PORT}}']
        labels:
          instance: local
