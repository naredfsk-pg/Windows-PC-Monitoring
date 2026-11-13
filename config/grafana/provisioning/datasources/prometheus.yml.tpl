apiVersion: 1

datasources:
  - name: PC Monitor Prometheus
    uid: pc-monitor-prometheus
    orgId: 1
    type: prometheus
    access: proxy
    url: 'http://127.0.0.1:{{PROMETHEUS_PORT}}'
    isDefault: true
    editable: false
    version: 1
    jsonData:
      httpMethod: POST
      prometheusType: Prometheus
      prometheusVersion: '3.16.0'
      timeInterval: '{{SCRAPE_INTERVAL}}'
      cacheLevel: Low
