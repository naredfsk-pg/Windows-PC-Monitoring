# Test matrix

This matrix distinguishes implemented automated checks from runtime acceptance. A static suite passing never establishes that services survive reboot, sensors work, mail is delivered, or Access rejects a remote identity.

## Local and CI checks

Run on Windows PowerShell 5.1, without Administrator rights:

```powershell
.\tests\Invoke-Checks.ps1 -Stage Foundation
.\tests\Invoke-Checks.ps1 -Stage Core
```

Foundation checks require real dependency metadata and contracts; missing deliverables fail. Core additionally requires the implementation, provisioned dashboards, and functional configuration regression suite. The tests do not install packages or services, send requests, read `.env`, or modify firewall/registry/power settings. Temporary functional fixtures must remain under the test-created temporary directory and be removed in `finally`.

The GitHub workflow runs Core checks on `windows-2022` using Windows PowerShell 5.1. A separate CI step downloads only the manifest-pinned Prometheus archive, verifies its SHA-256 before extraction/execution, then runs `promtool check rules` and the rule fixtures. The default local harness itself performs no downloads. Checkout is pinned to the [official v4.2.2 commit](https://github.com/actions/checkout/releases/tag/v4.2.2). This is a pinned candidate, not a claim that every third-party tool is current. No production credentials are available in CI.

The built-in credential-format scan is a limited regression guard for recognizable JWT/tunnel-token, private-key, and hosted-heartbeat formats. It is not a substitute for reviewing diffs, repository history, and a full secret scanner before release. Local ignored credential files are deliberately excluded from source content scans; their tracked/untracked status is checked without opening them.

## Acceptance coverage and evidence

Initial status for runtime cases below is **NOT RUN**. Record the tested commit or working-tree diff, UTC timestamp and timezone, Windows build, component versions/hashes, profile, sanitized command, exit code, expected/actual result, and PASS/FAIL/BLOCKED/NOT RUN with a reason. Do not add real tokens, command lines, personal telemetry, private messages, or machine inventory to public evidence.

| ID | Gate / owner | Adversarial checks and required proof | Runtime status |
|---|---|---|---|
| T01 | Core / QA | Fresh supported Windows x64 test host; local profile works with no owner account/domain/SMTP; invalid profile and occupied port fail before applying changes. | NOT RUN |
| T02 | Core / QA | All three core services start after reboot before login; record boot ID/times, service identity/start policy, actual scrape/UI checks. A running service before reboot does not pass. | NOT RUN |
| T03 | Core + hardware / QA | CPU/RAM/disk/network real values and units; history appears; distinguish counter reset and missing metrics from zero. Compare a declared sampling window with Windows tools. | NOT RUN |
| T04 | Core / QA | Process names/PIDs, aggregate vs instance, host-total CPU normalization; include zero, multi-core saturation fixture, PID reuse and counter-reset cases. Declare accuracy tolerance before measurement. | NOT RUN |
| T05 | Hardware / QA | Absent GPU/temperature becomes unsupported/unavailable; previously available sensor disappearing becomes stale/error according to capability baseline. Never healthy-by-default. | NOT RUN |
| T06 | Hardware / QA | Read-only SMART values cross-checked on a supported physical drive; map volume to actual device. Permission denied and unsupported devices remain explicit. | NOT RUN |
| T07 | MVP / QA | Dedicated synthetic metric triggers real alert and actual inbox receipt with correlation ID/timestamps; no stress/overheating; fixture cleanup on errors. | NOT RUN |
| T08 | MVP / QA | Synthetic alert resolves, actual recovery email arrives, grouping/dedup/repeat observed; duplicate events do not create a mail storm. | NOT RUN |
| T09 | MVP / QA | Stop exporter only on authorized host; target-down or missing-data state fires and resolves after restart; optional unsupported sensor is not equivalent to required target-down. | NOT RUN |
| T10 | Offline / QA | Suspend heartbeat with local monitoring unavailable; externally hosted service delivers DOWN email; record interval/grace and observed delivery delay. | NOT RUN |
| T11 | Offline / QA | Resume heartbeat; hosted RECOVERED mail and updated last-success observed; validate retry/timeout and maintenance snooze semantics. | NOT RUN |
| T12 | Owner / QA | Confirm actual FQDN/zone, valid HTTPS, allowed identity still reaches Grafana login, external links/callbacks use configured hostname. | NOT RUN |
| T13 | Owner / QA | External no-cookie client and denied identity cannot see Grafana; inspect all hostname/path routes; exporters and Prometheus have no public route. OTP sent-style UI alone is not approval evidence. | NOT RUN |
| T14 | Every gate / QA + reviewer | Recognizable credential scan, ignored local files not tracked, no raw process arguments/personal fixture data; inspect release diff/history and generated bundle separately. | NOT RUN |
| T15 | Core + operations / QA | Reinstall preserves config/secrets/history; hash/download/config/registration failures mid-install restore previous state; backup restores on separate installation; version-compatible rollback documented. | NOT RUN |
| T16 | Operations / QA | Isolated data directory, retention/time/size settings validated against selected binary; simulate low-space diagnostics safely. Do not claim global disk hard cap or exact 30 days when size guard wins. | NOT RUN |
| T17 | MVP / QA | SMTP auth failure, refusal, timeout and recovery remain visible locally; no claim that accepted SMTP means delivered email; no leaked secret in errors. | NOT RUN |
| T18 | Foundation + owner / QA | Generic defaults have no owner domain/email requirement; owner effective config changes recipient/timezone/URL only via explicit local override. Documentation examples are distinct from runtime defaults. | NOT RUN |
| T19 | Core + hardware / QA | Pin actual exporter version; record sanitized metric fixtures and executed queries; validate recording rules with that promtool version. JSON/PromQL text presence alone does not establish runtime correctness. | NOT RUN |
| T20 | Core + owner / QA | Check IPv4/IPv6 listeners and remote denial; Grafana anonymous/signup disabled; ordinary users cannot read secrets or alter service binary/config; inspect unexpected wildcard binds/routes. | NOT RUN |

## Test authorization and limitations

- Default CI/local checks are source parsing, data validation and temporary fixture work only. No deployment changes occur.
- Portable binary integration may use isolated loopback processes and temporary data only after its scope is accepted; it does not establish service persistence or hardware compatibility.
- Installing/stopping services or tasks, applying ACLs/firewall changes, disrupting connectivity and rebooting require existing authorization for the exact scenario or a concrete apply approval. Prefer a disposable VM; hardware needs a representative physical host.
- Real SMTP, hosted-check and Cloudflare tests require designated accounts/destinations and scoped authorization. Do not send messages to third parties or reuse unrelated credentials by inference.
- Missing provider, hardware or authorization means BLOCKED/NOT RUN for that runtime gate. It never becomes PASS because unit/static tests succeeded.
- A function-level fix requires a reproduction test that fails before the fix, passes afterward, and covers adjacent boundaries. Production owners apply fixes; QA verifies independently.

## Current automated evidence

On 2026-11-13, Windows PowerShell 5.1 ran 27 configuration behavior scenarios successfully, including restricted-data command rejection without sentinel creation, numeric port boundaries/collisions, invalid roots/owner URLs/control characters, override precedence and secret provisioning `-WhatIf` without writes or elevation. Foundation checks passed six checks after A0 files arrived.

Checksum-verified Prometheus 3.16.0 `promtool test rules tests/prometheus/core.test.yml` passed synthetic cases for two logical CPUs and one process core-equivalent yielding 0.5 host capacity, memory byte/ratio calculation, observed PID reuse suppressing a rate, missing-capacity/no-data behavior, and pseudo-process exclusion. `fuzzy_compare` ignores only the last mantissa bit of floating-point rate calculations, as documented by [Prometheus rule tests](https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/). These fixtures establish query semantics, not Task Manager accuracy on live hardware.

## Remaining coverage gaps

No implementation runtime was present when this matrix was created. Functional suites are added against accepted public contracts as the owning agents deliver code. No Windows services, reboot, sensors, actual mail delivery, hosted heartbeat or public Access tests have been run by the default checks.
