@{
    Profile = 'local'
    GrafanaPort = 3000
    PrometheusPort = 9090
    ExporterPort = 9182
    ScrapeInterval = '15s'
    RetentionTime = '30d'
    RetentionSize = '10GB'
    Timezone = 'browser'
    ProcessInclude = '.+'
    ProcessExclude = ''
    # InstallRoot and DataRoot default to dedicated PCMonitor directories under
    # Program Files and ProgramData. Never put passwords or tokens in this file.
}
