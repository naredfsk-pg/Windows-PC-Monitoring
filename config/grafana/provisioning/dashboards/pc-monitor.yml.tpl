apiVersion: 1

providers:
  - name: PC Monitor
    orgId: 1
    folder: PC Monitor
    folderUid: pc-monitor
    type: file
    disableDeletion: true
    updateIntervalSeconds: 30
    allowUiUpdates: false
    options:
      path: '{{GRAFANA_DASHBOARDS_PATH}}'
      foldersFromFilesStructure: false
