# Operations contract v1

## Installation transaction

1. Read and validate explicit configuration; inventory architecture, OS, .NET, ports and existing owned services. Produce a sanitized dry-run plan.
2. Fetch locked artifacts to an ignored staging/cache directory; verify SHA-256 before extraction/execution. Validate archive member destinations. These acquisition steps do not install anything.
3. On authorized elevated apply, create only owned roots/subdirectories and their ACLs. Stage versioned binaries and generated configuration; preserve current versions for rollback.
4. Provision a unique first-install Grafana secret only if missing, with protected ACLs in place first. Preserve existing secrets and Grafana DB credentials on rerun.
5. Install/update only owned service definitions; start with bounded readiness checks. Record completed steps without secrets.
6. Commit installation metadata after success. On failure restore prior configuration/services and stop/remove only resources created by this attempt. Preserve existing history and provide an actionable error. Do not claim rollback succeeded unless verified.

An installer rerun with the same inputs is idempotent. Upgrading does not mean deleting data, resetting Grafana credentials, importing new owner settings, or changing a tunnel. Failure halfway through download/extraction/configuration/startup must be diagnosable and leave existing data recoverable.

## Command behavior

Public entry scripts use PowerShell 5.1-compatible syntax. Mutating commands support `SupportsShouldProcess` and expose `WhatIf`; confirmation is the final apply boundary after the plan is concrete. Read-only `validate-config`, `status` and `doctor` never elevate or change host state.

Exit-code contract: `0` successful requested operation/healthy required checks; `1` failed operation or unhealthy required check; `2` invalid configuration/precondition; `3` privilege/authorization precondition not met. Distinguish capability unsupported from an unhealthy required target in structured output. Entry scripts catch and sanitize errors instead of dumping secrets or arbitrary upstream command lines.

Structured diagnostics include `SchemaVersion`, `TimestampUtc`, `OverallState` and `Checks[]` with name/state/detail fields. Details must not contain secrets, full process command lines, service executable arguments, private inventory exports or database contents. Optional unavailable sensors are shown as unavailable rather than silently zero/healthy. Human-readable diagnostics may summarize the same object.

## Data preservation and backup

Uninstall removes only owned services and optionally owned binaries. Config, secrets and historical data remain by default. Destructive data removal requires a separate explicit switch, a resolved-path preview, confirmation, and validation that targets are within the owned directory. Never recursively delete a caller-supplied unverified path.

The first backup implementation uses a controlled stop of owned Grafana and Prometheus services, copies configuration/provisioning plus complete Grafana/Prometheus state to a caller-selected protected backup destination, records exact component versions/hashes and a checksum inventory, then restores the prior running/stopped states even when the copy fails. This is a host-changing operation requiring authorization, not an automatic background feature. Never copy live SQLite/WAL files and label the result consistent without a supported consistency mechanism.

Secret files are excluded from the ordinary backup by default and explicitly reported as excluded. An opt-in secret backup must be separately confirmed, stored with restrictive ACLs and treated as plaintext sensitive material; no public artifacts. Document that a restore without secret files needs explicit re-provisioning and does not reset an existing Grafana admin password.

Restore validates backup integrity, component versions, destination ownership and available space, stops owned services, restores into staging, and only then swaps data/configuration. Test restoration on a separate installation first. A rollback to older Grafana binaries after database migration requires a compatible pre-upgrade data backup; never assume database downgrade compatibility.

## Verification levels

- Static/unit: parsing, config/secret redaction boundaries, safe rendering, manifest validation, artifact hash rejection, dry-run and simulated partial failure; no production secrets or services.
- Portable process smoke: pinned binaries, isolated workspace data and loopback ports, no SCM changes; records actual CLI/query/fixture compatibility. Does not prove a service identity or reboot behavior.
- Approved service integration: installation, ACLs, lifecycle/recovery and reboot/no-login tests on the authorized test host.
- External feature verification: actual email receipt, hosted offline notifications and Cloudflare allowed/denied access require their own accounts/credentials and scoped authorization.

Record PASS/FAIL/SKIPPED/BLOCKED with expected/observed behavior, commands/exit codes, component hashes, Windows build and timestamps. A mocked assertion or service Running cannot substitute for runtime delivery, accurate hardware data or successful remote authorization denial.

Prometheus time and size retention apply to its TSDB management; they are not a hard filesystem quota over WAL, logs and all installation files. Monitor actual disk pressure, report retention truncation and do not promise a full 30 days when the configured size threshold is reached.
