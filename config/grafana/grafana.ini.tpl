# Grafana OSS 13.3.1. Render with Write-MonitorConfiguration; keep credentials out of this file.
app_mode = production
instance_name = pc-monitor

[paths]
data = {{GRAFANA_DATA_PATH}}
logs = {{GRAFANA_LOG_PATH}}
plugins = {{GRAFANA_DATA_PATH}}/plugins
provisioning = {{GRAFANA_PROVISIONING_PATH}}

[server]
protocol = http
http_addr = 127.0.0.1
http_port = {{GRAFANA_PORT}}
root_url = {{GRAFANA_URL}}
serve_from_sub_path = false
enforce_domain = false
router_logging = false
enable_gzip = true

[security]
admin_user = admin
admin_password = $__file{{{GRAFANA_ADMIN_SECRET_PATH}}}
disable_gravatar = true
cookie_secure = {{GRAFANA_COOKIE_SECURE}}
cookie_samesite = lax
allow_embedding = false

[users]
allow_sign_up = false
allow_org_create = false
default_theme = system

[auth]
disable_login_form = false

[auth.basic]
enabled = true

[auth.anonymous]
enabled = false

[public_dashboards]
enabled = false

[snapshots]
external_enabled = false

[analytics]
reporting_enabled = false
check_for_updates = false
check_for_plugin_updates = false

[dashboards]
default_home_dashboard_path = {{GRAFANA_DASHBOARDS_PATH}}/overview.json
min_refresh_interval = 15s

[date_formats]
default_timezone = {{TIMEZONE}}

[log]
mode = file
level = info

[log.file]
log_rotate = true
max_days = 7
