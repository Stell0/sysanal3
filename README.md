# sysanal3

**NethServer 8 System Analyzer V3** — Analyzes a NethServer 8 system and automatically searches for known issues.

## Quick Start

Run as **root** on a NethServer 8 node:

```bash
bash <(curl -sfL https://raw.githubusercontent.com/Stell0/sysanal3/main/sysanal3)
```

Run in silent mode to suppress `OK` messages and most `INFO` messages while still printing the full **General System Data** section:

```bash
bash <(curl -sfL https://raw.githubusercontent.com/Stell0/sysanal3/main/sysanal3) --silent
```

Get a machine-readable report on stdout (human-readable output goes to stderr), or skip all external lookups and active probes:

```bash
bash <(curl -sfL https://raw.githubusercontent.com/Stell0/sysanal3/main/sysanal3) --json 2>/dev/null
bash <(curl -sfL https://raw.githubusercontent.com/Stell0/sysanal3/main/sysanal3) --offline
```

The node role is detected automatically (the leader runs the Redis master); worker-specific checks run on worker nodes.

## What it does

The script executes a series of automated checks and reports all detected **problems** and **warnings**.
It exits with code `1` if any problem is found, otherwise `0`.

### Checks performed

- **Internet connectivity precheck** — Pings `sos.nethesis.it`; if unreachable, GitHub version checks are skipped.
- **General System Data** — IP addresses, DNS nameservers, hostname/FQDN, open file descriptors, root filesystem block and inode usage (warning at 85%, problem at 95%), read-only disk filesystems, usage of filesystems containing local module homes (shared mounts reported once, excluding the already reported root filesystem), available memory and swap usage, CPU load average (warns if 1-minute load is above the core count, problem if above $2\times$ the core count), uptime, timezone, NTP synchronization, pending reboot (`needs-restarting -r` or `/run/reboot-required`), SELinux denials today, cluster subscription `system_id` (warns if missing), cluster UUID.
- **Long-running sngrep** — Flags `sngrep` processes running for more than 1 day.
- **Log size and journal errors** — Warns when the active `/var/log/messages` exceeds 1 GiB (naming its top sources), and summarizes error-priority journal entries of the last 24 hours by source, warning for noisy sources and reporting known error patterns. Records are never printed.
- **Module inventory** — Lists all modules installed on the node and reports the node role and registered node count.
- **Cluster VPN** — Each WireGuard peer without a handshake in the last 5 minutes is a problem, named by node; the leader warns for registered nodes without a peer. Workers verify the Redis replication link to the leader. Redis persistence failures are problems.
- **Backups** — Warns for local modules in no enabled backup, overdue or never-completed runs, backups referencing removed modules, and enabled backups without installed modules; failed runs are problems.
- **Leftover module homes** — Warns for homes of removed modules (with size and whether their UID was reused by another account).
- **NS8 updates and subscription** — Warns when no software repository is enabled, reports the core version, and on the leader lists module and core updates offered by NS8 (`cluster/list-updates`, `cluster/list-core-modules`) and the subscription status and expiry.
- **Rootful Podman storage** — Reports image and volume usage and warns when more than 10 GB of images are unused.
- **Module version check** — Compares installed module versions against the latest GitHub release (skipped without internet).
- **Per-module container health** — Lists container IDs, then inspects only name, state, restart count, OOM status, and configured healthcheck status. Flags stopped/paused containers (warning), excess restarts, dead containers, OOM kills, and unhealthy containers (problems). Rootful inspection selects NS8 module-owned container names in the shared host Podman context.
- **Failed services** — Reports each failed system unit by name and queries module service properties with the user manager for rootless modules or module-owned system units for rootful modules.
- **Inactive services and restarts** — Warns for enabled inactive daemons and unsuccessful last runs. Successful oneshots, timer/socket/path-triggered services, disabled features, and unmet start conditions are allowed to be inactive. Failed units and repeated automatic-restart state above the threshold are problems. High restart counts warn when the unit started within the last day; units stable for longer report them as information.
- **Bounded log scans** — Scans `/var/log/messages` and each NethVoice active `/var/log/asterisk/full` in one pass over at most the last 1 MiB and 20,000 lines, with a 15-second timeout. Reports matching error patterns without printing log records. Rotated archives are excluded; historical investigation needs a separate scoped query.
- **Memory pressure** — Uses `MemAvailable` to account for reclaimable cache, warns at 90% usage, and reports a problem at 95%. Memory and swap totals remain visible with `--silent`.
- **NethVoice-specific checks**:
  - DNS resolution via `getent hosts ibm.com`.
  - MySQL integrity via `mysqlcheck` (password passed through `MYSQL_PWD`).
  - FreePBX pending configuration (`need_reload`, i.e. Apply Config not done) and cluster smarthost configuration (warnings).
  - MariaDB `asterisk.kvstore_Sipsettings` `localnets` check (problem if a `localnets` row exists).
  - FreePBX email sender check (warns if neither `SMTP_FROM_ADDRESS` nor `voicemail.conf` `mailcmd=...send_email -f ...` is configured).
  - Validates the certificate presented by each local `nethvoice-proxy` `KML_DEFAULT_FQDN` on ports `443` and `5061` (TLS handshake, hostname match, non-expired certificate).
  - Collects domain-to-URI routes from local `nethvoice-proxy` modules and verifies each instance against its configured node-local `PROXY_IP` and SIP UDP port (`ASTERISK_SIP_UDP_PORT` when present, otherwise legacy `ASTERISK_SIP_PORT`). Older environments without `PROXY_IP` use the local `wg0` address; IPv6 destinations use brackets. A configured proxy address outside this node is a problem.
  - Validates the certificate presented by each instance `NETHVOICE_HOST` on port `443` (TLS handshake, hostname match, non-expired certificate).
  - Asterisk version, uptime, last reload age, and aggregate active-call/channel counts. Failed or malformed queries are reported separately from zero counts.
  - Asterisk PJSIP contact-object count from `Objects found`, filtered inside the container so contact URIs are not collected (warns if zero while the CLI is running).
  - PJSIP endpoint counts (configured/unavailable), outbound registrations not registered (problem), and channels older than 4 hours (warning), all reduced to counts inside the container.
  - nethvoice-proxy Kamailio dispatcher destinations (inactive or disabled is a problem), RTPengine availability, and proxy `PUBLIC_IP` versus the detected public IP.
  - AstDB `AMPUSER//cidname` check (warns if an empty-extension `cidname` entry exists and suggests `database del AMPUSER/ cidname` in the Asterisk CLI).
  - AstDB call forward check (warns for each extension with `CF` enabled and flags circular forwarding chains as problems).
  - Asterisk queue ring strategy check (warns if more than 3 queues use `ringall`, or any `ringall` queue has more than 5 agents).
  - Validates NethVoice `*PORT*` environment variables against listening processes (e.g. Asterisk/Kamailio ownership checks).
  - Verifies Asterisk expected listening ports, enforces that Asterisk is not listening on `5060`/`5061`, and checks PJSIP transport port alignment. Separately allocated SIP UDP listeners are checked explicitly as UDP.
- **Listening ports** — Verifies expected ports are in LISTEN state for installed services, selected by image name (Traefik 80/443, Samba 389/636, Mail 25/143/993), and checks NethVoice SIP/SIPS ports from module environment (`PROXY_PORT`, `ASTERISK_SIP_PORT`, optional `ASTERISK_SIP_UDP_PORT`, `ASTERISK_SIPS_PORT`) with process-owner validation.
- **Hairpin NAT** — Probes the public IP on the configured `PROXY_PORT` (UDP/TCP SIP OPTIONS), Kamailio TLS 5061, and a free port of the proxy RTP range.
- **CrowdSec** — If present, checks whether any local IP is blocked.

The certificate checks require `openssl` to be available on the host. If `openssl` is missing, the script reports that the related certificate checks were skipped.

## Module paths and filesystem reporting

Module environment checks support relocated Unix account homes and custom NS8
state directories, including rootful modules without a matching Unix account.
For each local module, the analyzer first runs:

```bash
timeout 15s runagent -m "$mod" sh -c 'id -u || exit 1; printenv AGENT_STATE_DIR || exit 3' </dev/null 2>/dev/null
```

The first line is the module execution UID (rootless or rootful context); the
rest must be one nonempty absolute directory path. The
analyzer reads its `environment` file. If runtime discovery fails or returns an
invalid path, `getent passwd "$mod"` supplies the matching account's home from
field 6, and the fallback is `<account-home>/.config/state/environment`. No fixed
home prefix is assumed. Paths containing spaces are supported, and the
analyzer's `HOME` is unchanged.

A valid runtime path remains authoritative: if its environment file is missing,
not a regular file, or unreadable, the analyzer reports that path rather than
using a potentially stale fallback. Successes and failures are cached for the
run. Each failed module emits one actionable path warning and skips only checks
that need the environment; independent diagnostics continue. Environment files
are read for specific values and are never sourced or evaluated.

After module discovery, the analyzer reports capacity for filesystems containing
NSS-resolved module homes, including homes outside `/home`. Shared mount targets
are reported once, and the root filesystem report is not repeated. Block or
inode usage at or above 85% warns and at or above 95% is a problem. These
reports remain visible with `--silent`.

## Performance

On NS8 every `runagent` and `redis-cli` invocation starts a helper process,
which takes seconds on loaded nodes. The analyzer therefore combines per-module
queries (context, container inventory and health, FreePBX/MariaDB/proxy
snapshots), batches single-line Redis reads into one `redis-cli` process, and
runs slow read-only queries in parallel while the cluster checks proceed.

## Local regression tests

The tests use temporary fixtures and mocked commands; they do not require an
NS8 node or run the full analyzer. Sourcing `sysanal3` defines its helpers without
starting diagnostics. The diagnostic suite also covers rootful scoping, conditional
services, OOM/health failures, memory thresholds, Asterisk summaries, unavailable
commands, and configured proxy addresses. The normal direct and `bash <(curl …)` launches still run
all checks.

```bash
bash -n sysanal3
bash tests/test_module_paths.sh
bash tests/test_diagnostics.sh
bash tests/test_log_scans.sh
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck sysanal3 tests/test_module_paths.sh tests/test_diagnostics.sh tests/test_log_scans.sh
fi
```

## Arguments

| Flag | Description |
|------|-------------|
| `-s`, `--silent` | Suppress `OK` messages and most `INFO` messages. Warnings, problems, headers, the full General System Data section, and the final summary are still printed. |
| `--json` | Print a JSON report (`node_id`, `cluster_role`, counts, `problems`, `warnings`) on stdout; human-readable output goes to stderr. The exit code is unchanged. |
| `--offline` | Skip external lookups and active probes: public IP services, GitHub, TLS handshakes, hairpin NAT, NS8 update listing and subscription status. |
| `--worker` | Accepted for compatibility; the node role is detected automatically. |

## Configurable constants

| Constant | Default | Description |
|----------|---------|-------------|
| `LOG_SCAN_MAX_BYTES` | `1048576` | Maximum bytes inspected from the tail of each active log. |
| `LOG_SCAN_MAX_LINES` | `20000` | Maximum lines inspected within that byte tail. |
| `LOG_SIZE_WARNING_BYTES` | `1073741824` | Active `/var/log/messages` size that warns. |
| `JOURNAL_SCAN_HOURS` | `24` | Error-priority journal window. |
| `JOURNAL_NOISY_SOURCE_COUNT` | `1000` | Journal error entries from one source that warn. |
| `RESTART_THRESHOLD` | `5` | Container restart problem threshold; service restart warning threshold (problem when repeatedly auto-restarting). |
| `RESTART_RECENT_SECONDS` | `86400` | Units stable for longer report high restart counts as information. |
| `RUNAGENT_TIMEOUT` | `15` | Seconds allowed for each module-context `runagent` query. |
| `FS_WARNING_PCT` / `FS_PROBLEM_PCT` | `85` / `95` | Filesystem block and inode usage thresholds. |
| `NV_CHANNEL_MAX_AGE` | `14400` | Asterisk channel age (seconds) that warns. |
| `WG_HANDSHAKE_MAX_AGE` | `300` | WireGuard handshake age (seconds) that flags an unreachable node. |
| `BACKUP_AGE_GRACE_SECONDS` | `3600` | Slack added to twice the backup interval before a run is overdue. |
| `PODMAN_RECLAIMABLE_WARNING_BYTES` | `10000000000` | Unused rootful image size that warns. |
| `SUBSCRIPTION_EXPIRY_WARNING_DAYS` | `30` | Subscription expiry warning window. |
| `MAX_PARALLEL_QUERIES` | `8` | Background query concurrency. |
| `MEMORY_WARNING_PCT` | `90` | Effective memory usage percentage above which a warning is flagged. |
| `MEMORY_PROBLEM_PCT` | `95` | Effective memory usage percentage above which a problem is flagged. |
| `DNS_SLOW_MS` | `2000` | DNS resolution time (ms) above which a problem is flagged. |
| `QUEUE_RINGALL_MAX_QUEUES` | `3` | Ringall queue count above which a warning is flagged. |
| `QUEUE_RINGALL_MAX_AGENTS` | `5` | Agent count in a ringall queue above which a warning is flagged. |

## References

- [NethServer 8 Developer Manual](https://nethserver.github.io/ns8-core/)
- [NethServer 8 Administrator Manual](https://docs.nethserver.org/projects/ns8/en/latest/)

## License

See the [repository](https://github.com/Stell0/sysanal3) for license details.

## Credits
- Thanks to Nick and NethAnal for inspiring this project and providing part of the codebase.
