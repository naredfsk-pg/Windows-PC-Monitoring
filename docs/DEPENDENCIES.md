# Dependency candidates and provenance

Checked 2026-11-13 against official distribution sources. The lock file fixes exact artifacts; these are candidates for this implementation, not a claim of complete integration testing. Never resolve `latest` at install time.

| Component | Pinned candidate | Artifact | SHA-256 provenance |
|---|---|---|---|
| Prometheus | 3.16.0 | Windows AMD64 ZIP | Official GitHub release API asset digest |
| windows_exporter | 0.32.1 | Windows AMD64 EXE | Official GitHub release API asset digest; portable smoke independently checked by A3 |
| Grafana OSS | 13.3.1 | Windows AMD64 TAR.GZ | Official Grafana OSS download page SHA-256 |
| WinSW | 2.12.0 | NET461 EXE | Computed SHA-256 of the official release download; release API has no digest for this old asset |

Exact URLs/hashes are in [`config/dependencies.lock.json`](../config/dependencies.lock.json). Prometheus and Grafana archives are extracted into staging first. Strip one enclosing distribution directory when present, then validate `executableRelativePath`. Raw EXE artifacts are copied under the normalized executable name. Reject absolute or parent-traversing archive members and never overwrite arbitrary paths during extraction.

The WinSW NET461 build uses installed .NET Framework rather than the self-contained x64 build's old .NET Core runtime. Require .NET Framework 4.6.1 or later (Windows 10/11 targets normally provide a later release); check the actual machine and do not install or change .NET silently. The NET461 distribution is suitable for the x64 target but is not named `WinSW-x64.exe`. [WinSW tagged README](https://github.com/winsw/winsw/blob/v2.12.0/README.md) documents these build variants.

## Official evidence

- [Prometheus v3.16.0 release](https://github.com/prometheus/prometheus/releases/tag/v3.16.0), [release API](https://api.github.com/repos/prometheus/prometheus/releases/tags/v3.16.0), and [release checksum list](https://github.com/prometheus/prometheus/releases/download/v3.16.0/sha256sums.txt).
- [windows_exporter v0.32.1 release](https://github.com/prometheus-community/windows_exporter/releases/tag/v0.32.1), [release API](https://api.github.com/repos/prometheus-community/windows_exporter/releases/tags/v0.32.1), and [tagged documentation](https://github.com/prometheus-community/windows_exporter/tree/v0.32.1/docs).
- [Grafana OSS Windows download](https://grafana.com/grafana/download?platform=windows&edition=oss) displayed 13.3.1, released 2026-11-10, and the locked SHA-256 when checked. The download page changes with future releases; the artifact URL in the lock does not.
- [Grafana Windows installation](https://grafana.com/docs/grafana/latest/setup-grafana/installation/windows/) and [configuration/file provider](https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/).
- [WinSW v2.12.0 release](https://github.com/winsw/winsw/releases/tag/v2.12.0), [tagged XML service configuration](https://github.com/winsw/winsw/blob/v2.12.0/doc/xmlConfigFile.md), and [tagged license](https://github.com/winsw/winsw/blob/v2.12.0/LICENSE.txt).

Read-only release metadata retrieval and the WinSW download/hash calculation completed successfully. There was no WinSW service installation or service-account/reboot smoke during A0. Metadata alone does not establish artifact execution, Grafana provisioning compatibility, or Windows build compatibility.

## Artifact verification and updates

Download only the locked HTTPS URL, store it in an ignored cache, calculate SHA-256, and compare before extraction or execution. Fail closed on a mismatch. Do not automatically substitute a mirror, another edition, or another version. Download failures leave existing installations intact.

The installer downloads upstream software for the local user; the repository does not vendor binaries. Releasing an archive that bundles upstream software is a separate redistribution/license gate, particularly for Grafana. Source availability and upstream notices must remain accessible as required by the applicable licenses.

Updating a lock requires checking upstream support/security notes, collector flags, metric fixtures, Grafana provisioning, wrapper/service smoke, license changes, and the relevant regression gates. Keep the previous manifest for rollback evidence; do not imply older database formats can read a migrated Grafana database.
