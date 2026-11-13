# Third-party components

Original PC Monitor scripts, configuration and documentation use the MIT License in `LICENSE`. That license does not replace upstream terms.

The installer retrieves unmodified upstream artifacts separately. No third-party executable is checked into this repository. Bundling binaries in a future release requires a fresh redistribution audit and copies of the relevant upstream notices/source offers where applicable.

| Component | Candidate version | Upstream license | Source / license |
|---|---|---|---|
| Prometheus | 3.16.0 | Apache License 2.0 | [source](https://github.com/prometheus/prometheus/tree/v3.16.0), [license](https://github.com/prometheus/prometheus/blob/v3.16.0/LICENSE), [notice](https://github.com/prometheus/prometheus/blob/v3.16.0/NOTICE) |
| windows_exporter | 0.32.1 | MIT | [source](https://github.com/prometheus-community/windows_exporter/tree/v0.32.1), [license](https://github.com/prometheus-community/windows_exporter/blob/v0.32.1/LICENSE) |
| Grafana OSS | 13.3.1 | GNU Affero General Public License v3.0 | [source](https://github.com/grafana/grafana/tree/v13.3.1), [license](https://github.com/grafana/grafana/blob/v13.3.1/LICENSE) |
| WinSW | 2.12.0 | MIT | [source](https://github.com/winsw/winsw/tree/v2.12.0), [license](https://github.com/winsw/winsw/blob/v2.12.0/LICENSE.txt) |

Keep the copyright/license/NOTICE files shipped inside retrieved distributions. Grafana OSS remains AGPL software even though the surrounding PC Monitor integration is MIT. Modifying or redistributing Grafana itself carries its own obligations; do not describe a bundled distribution as entirely MIT or promise proprietary use of every third-party component without reviewing its terms.

Cloudflare `cloudflared`, hardware exporters, SMART tooling and hosted heartbeat services are outside this initial dependency lock. Their own licenses/terms must be reviewed before packaging or enabling the corresponding extension. The core installer does not own the user's existing cloudflared service.

This is an inventory and implementation boundary, not a complete transitive-license certification. Release packaging must audit included dependencies/plugins and preserve their notices.
