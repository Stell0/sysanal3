# AGENTS.md - sysanal3

## Purpose

The `sysanal3` script analyzes a NethServer 8 system and automatically searches for known issues.

## Scope

- Analyze the current node and check all modules running on this node.
- Execute a list of automated checks.
- Print all detected problems and warnings.

## References

- NethServer 8 developer manual: https://nethserver.github.io/ns8-core/
- NethServer 8 administrator manual: https://docs.nethserver.org/projects/ns8/en/latest/

## Execution

Run the script with:

```bash
bash <(curl -sfL https://raw.githubusercontent.com/Stell0/sysanal3/main/sysanal3)
```

## Expected output

The script executes all checks and outputs detected problems and warnings.
It exits with code `1` if problems are found, otherwise `0`.

## List of checks

- **Internet connectivity precheck**: `ping -qc 1 -W 3 sos.nethesis.it`. If unreachable, GitHub version checks are skipped. `--offline` skips it.
- **General System Data**: IP addresses, DNS nameservers, hostname/FQDN, open file descriptors, root filesystem block and inode usage (warning at `FS_WARNING_PCT`, problem at `FS_PROBLEM_PCT`), read-only ext/xfs/btrfs mounts (problem), usage of filesystems containing local module homes (shared mounts reported once, excluding the already reported root filesystem), available memory and swap usage, CPU load average (warns if 1-minute load is above the core count, problem if above 2x the core count), uptime, timezone, NTP synchronization (`timedatectl show -p NTPSynchronized`, warning), reboot required (`needs-restarting -r` or `/run/reboot-required`, warning), SELinux AVC denials today (`ausearch`, warning), cluster subscription `system_id` (warns if missing), cluster UUID.
- **Bounded log scans**: Scan the last `LOG_SCAN_MAX_BYTES=1048576` bytes and at most `LOG_SCAN_MAX_LINES=20000` lines of `/var/log/messages` and the active Asterisk full log in a single pass with a 15-second timeout. Print matching pattern names only, never raw log records. Do not scan rotated archives by default; older history requires a separate scoped investigation.
- **Log size and journal errors**: Warn when the active `/var/log/messages` is at least `LOG_SIZE_WARNING_BYTES` and name the top program names in the scanned tail. Read at most `LOG_SCAN_MAX_LINES` error-priority journal entries (`journalctl -p 0..3`) from the last `JOURNAL_SCAN_HOURS`; report counts per source, warn for sources with at least `JOURNAL_NOISY_SOURCE_COUNT` entries, and report matching `/var/log/messages` pattern names as problems. Never print journal records.
- **Cluster role and VPN**: The leader is the node whose Redis `ROLE` is `master`; workers are replicas (fallback: node ID 1 is the leader, with a warning). On every node, each `wg show wg0 dump` peer without a handshake within `WG_HANDSHAKE_MAX_AGE` is a problem, named by node through `node/*/vpn` `ip_address`. The leader warns for registered nodes without a peer. Workers also check `redis-cli info replication` `master_link_status:up` (problem otherwise). Redis `rdb_last_bgsave_status`/`aof_last_write_status` failures are problems.
- **Backups**: Read `cluster/backup/<id>` (`name`, `enabled`, space-separated `instances`, `schedule_hint`) and `node/<node>/backup_status/<id>` JSON (`end`, `errors`). Local modules without the `no_data_backup` flag in `module/<id>/flags` that are in no enabled backup warn; a last run with errors is a problem; a last run older than twice the hinted interval plus `BACKUP_AGE_GRACE_SECONDS`, or never completed, warns. The leader also warns for backups referencing removed modules and for enabled backups with no installed module.
- **Leftover module homes**: Under `/home` and the parent directories of resolved module homes, directories named like module IDs, with NS8 state (`.config/state`, `.local/share/containers` or `.config/systemd`) and absent from `cluster/module_node`, warn with their size and whether their owner UID has no account or was reused by another account.
- **NS8 software updates**: Warn when no `cluster/repository/*` has `status` 1. Report the node core version. On the leader only (skipped with `--offline`), use `api-cli run cluster/list-updates` and `cluster/list-core-modules` and warn for each offered `update`. The GitHub release comparison is kept as a separate check.
- **Subscription status**: On the leader only (skipped with `--offline`), `api-cli run cluster/get-subscription` status other than `active` warns; when it expires, expiry within `SUBSCRIPTION_EXPIRY_WARNING_DAYS` warns and a past expiry is a problem. Read only `status`, `expires` and `expire_date`.
- **Rootful Podman storage**: `podman system df` image, reclaimable and volume sizes; warn when reclaimable images reach `PODMAN_RECLAIMABLE_WARNING_BYTES`.
- Check for `sngrep` instances running for more than 1 day.
- List all modules in this node.
- For all modules, check if the installed version is older than the latest released version (latest release from GitHub). Skipped if no internet.
- **Per-module container health**: Use `podman ps -a` for IDs/names and selected `podman inspect --format` fields for state, restart count, OOM and health status. Flag stopped/paused containers, excess restarts, dead containers, OOM kills and unhealthy containers. Rootful Podman is shared: inspect only names equal to the module ID or beginning with `<module-id>-`. Show `TRAEFIK_HOST` if set.
- Check system-wide failed units (one problem per unit, named) and module-owned services in the appropriate systemd manager.
- **Module service expectations**: Use `systemctl show` properties (`Id`, `Type`, `LoadState`, `ActiveState`, `SubState`, `UnitFileState`, `Result`, `NRestarts`, `TriggeredBy`, `ConditionResult`, `ActiveEnterTimestampMonotonic`). Enabled inactive daemons warn; successful oneshots, disabled features, triggered services and unmet conditions may be inactive. Failed services and repeated auto-restart state above the threshold are problems. Other restart counts above the threshold warn when the unit last started within `RESTART_RECENT_SECONDS` (or the start time is unknown) and are informational when the unit has been stable longer, e.g. agents that restarted while Redis was down during a core update. Cache each unit `ActiveState` for later checks (Satellite port skips).
- **Node memory pressure**: Use `/proc/meminfo` `MemAvailable` rather than free memory alone; warn at 90% used, flag a problem at 95%, and show memory/swap totals even with `--silent`. Missing measurements are warnings, not exhaustion findings.
- For all NethVoice modules:
	- Check DNS by running `getent hosts ibm.com`.
	- Run `mysqlcheck` (always, even when slow; credentials via `MYSQL_PWD`, never argv).
	- **MariaDB `asterisk.kvstore_Sipsettings` localnets**: Flags a problem if a `localnets` row exists.
	- **FreePBX pending reload**: Warns when `asterisk.admin` `need_reload` is `true` (Apply Config pending).
	- **Cluster smarthost**: Warns once when `cluster/smarthost` `enabled` is not `1` and a NethVoice module is installed.
	- **FreePBX email sender**: Warns if neither `SMTP_FROM_ADDRESS=...` in the `freepbx` container nor `/etc/asterisk/voicemail.conf` `mailcmd=/var/lib/asterisk/bin/send_email -f ...` is configured.
	- **Asterisk runtime**: Query `core show version`, `core show uptime seconds`, and `core show channels count`; print only version, uptime/reload age and aggregate counts. Preserve command failure versus zero counts.
	- **Asterisk PJSIP contacts**: Parse `Objects found` inside the container, without returning contact URIs. Warn if zero and the CLI is running.
	- **PJSIP endpoints, registrations and channels**: Reduced to counts inside the container. Report configured/unavailable endpoints; outbound registrations in `Rejected`, `Unregistered` or `Stopped` state are a problem; channels older than `NV_CHANNEL_MAX_AGE` (`core show channels concise` duration) warn.
	- **Asterisk AstDB AMPUSER cidname**: Warns if an entry with empty extension exists, such as `/AMPUSER//cidname`, and suggests running `database del AMPUSER/ cidname` in the Asterisk CLI.
	- **Asterisk AstDB call forward (CF)**: Warns for each extension that has `CF` enabled and flags circular call forward chains as problems.
	- **Asterisk queue ring strategy**: Warns if more than 3 queues use `ringall`, or if any `ringall` queue has more than 5 agents.
	- Validate NethVoice `*PORT*` environment variables against listening processes (Asterisk/Kamailio ownership checks).
	- Verify expected Asterisk listening ports, enforce that Asterisk is not listening on `5060`/`5061`, and verify PJSIP transport alignment with `ASTERISK_SIP_PORT`.
- **nethvoice-proxy runtime**: Kamailio `kamcmd dispatcher.list` destinations whose first flag is `I` or `D` are problems (`A` is active, others warn as probing; no destinations warn). `rtpengine-ctl list numsessions` failure is a problem. When the public IP came from a lookup, a different proxy `PUBLIC_IP` warns.
- **Listening ports**: For installed services (selected by image name, not module ID prefix), verifies ports are in LISTEN state (Traefik 80/443, Samba 389/636, Mail 25/143/993). For NethVoice, uses module environment values (`PROXY_PORT`, `ASTERISK_SIP_PORT`, optional `ASTERISK_SIP_UDP_PORT`, `ASTERISK_SIPS_PORT`) and validates process ownership.
- **Hairpin NAT**: When the public IP is not local, send SIP OPTIONS over UDP/TCP to the instance `PROXY_PORT` (default 5060), a TLS handshake to Kamailio 5061, and a UDP datagram to the first free port after `RTP_PORT_MIN` in the local proxy RTP range (10001 without a proxy). Skipped with `--offline`.
- If CrowdSec is present (warning):
	- Check whether any network interface IP is blocked, in one module-context call.
	- Example command: `cscli decisions list -i "1.2.3.4" -o raw`.
- **Node context info**: Detects local node ID and reports leader/worker role and the number of registered nodes.

## NethServer 8-specific commands and practices used

### NS8 command usage

- `runagent -m <module-id> ...`
	- Core NS8 module-context execution primitive used throughout the script.
	- Used to run module-scoped `podman`, `systemctl --user`, and in-container checks (`podman exec`).
- `redis-cli --raw ...` against NS8 Redis keyspace
	- Used to read cluster and module metadata from NS8 control-plane data.
	- NS8 `redis-cli` is itself started through `runagent` (about one second on loaded nodes). Batch single-line replies (`HGET`, `GET`, `SISMEMBER`) through `redis_batch` (commands on stdin, one reply line each, empty for nil); keep `--scan`, `HGETALL`, `ROLE` and `INFO` as separate calls. Always detach stdin (`</dev/null`) for single calls inside loops.
- `api-cli run cluster/<action>`
	- Leader only, read-only actions: `list-updates`, `list-core-modules`, `get-subscription`. Parse with `jq`; skip when `api-cli` or `jq` is missing.

### NS8 Redis data structures / keys

- `cluster/subscription` (hash)
	- Field used: `system_id` (`HGET cluster/subscription system_id`).
- `cluster/uuid` (string)
	- Retrieved with `GET cluster/uuid`.
- `cluster/module_node` (hash)
	- Mapping `module_id -> node_id` via `HGETALL cluster/module_node`.
- `module/<module-id>/environment` (hash)
	- Field used: `IMAGE_URL` (`HGET module/<id>/environment IMAGE_URL`).
- `node/*/vpn` keys pattern
	- Enumerated with `--scan --pattern 'node/*/vpn'`; field `ip_address` maps WireGuard peers to node IDs.
- `cluster/backup/<id>` (hash) and `node/<node>/backup_status/<id>` (hash `module_id -> JSON`)
	- Backup definitions and per-module results (see Backups check).
- `module/<module-id>/flags` (set)
	- `no_data_backup` exempts a module from backup coverage warnings.
- `cluster/repository/<name>` (hash)
	- Fields `status` and `testing`.
- `cluster/smarthost` (hash)
	- Fields `enabled` and `host` only; never read or print `password`.

### NS8 filesystem and runtime conventions

- Node identity files:
	- `/var/lib/nethserver/node/state/environment` (reads `NODE_ID`).
	- `/var/lib/nethserver/node/state/agent.env` (fallback from `AGENT_ID=node/<id>`).
- Module state environment file:
	- Resolve once per local module with one `timeout ${RUNAGENT_TIMEOUT}s runagent -m <module-id> sh -c 'id -u || exit 1; printenv AGENT_STATE_DIR || exit 3' </dev/null 2>/dev/null` call that yields the execution UID (first line) and the state directory; status 3 means only the UID is known. Require successful status and one nonempty absolute directory path, then append `/environment`.
	- If runtime discovery fails or is invalid, use `getent passwd <module-id> </dev/null 2>/dev/null`, validate the matching account name, and read home field 6. The fallback is `<account-home>/.config/state/environment`.
	- Relocated homes, paths with spaces, and custom rootful state directories without Unix accounts are supported; do not assume `/home` or `/home2` or change the analyzer's `HOME`.
	- A valid runtime directory is authoritative even if its environment file is missing or unreadable. Require a regular, readable file and never silently use a stale fallback.
	- Cache successes and failures in the parent Bash process. Emit one actionable warning per failed module, skip environment-dependent checks, and continue independent diagnostics. Do not call `warning()` inside path-returning command substitutions.
	- Read targeted values only; never source/eval environment files or print their full contents or credentials.
	- Reused by `TRAEFIK_HOST` reporting, configured port auditing, proxy certificates, NethVoice certificates/routes/Asterisk alignment, and NethVoice listening-port checks.
- Module home filesystem reporting:
	- Use NSS-resolved local homes with `findmnt -n -o TARGET --target <home>` and quoted `df -P -- <home>` / `df -h -- <home>`.
	- Report each shared mount once after module discovery and avoid repeating root. Apply the `FS_WARNING_PCT`/`FS_PROBLEM_PCT` block and inode thresholds and keep visibility with `--silent`.
- Per-module systemd context:
	- Cache the execution UID from the same context call to distinguish rootless/rootful execution; never infer context solely from an NSS account.
	- Rootless services use `runagent -m <id> systemctl --user show ...`; rootful services use the system manager scoped to `<id>.service` and `<id>-*.service`.
	- Runtime queries use bounded timeouts, detached stdin, selected properties, and fixed failure messages instead of raw stderr.
- NethVoice proxy address:
	- Route checks prefer targeted `PROXY_IP` from the resolved environment and verify node-local address ownership, with `wg0` fallback for older environments and bracketed IPv6 destinations. Use `ASTERISK_SIP_UDP_PORT` when defined, falling back to `ASTERISK_SIP_PORT` only for older shared-port versions; malformed UDP values must not fall back to TCP. Check separately allocated UDP listeners with UDP socket queries.
- Per-module container model:
	- Module containers are listed and inspected (selected fields only) in one `runagent -m <id> sh -c` call; rootful listings are filtered to module-owned names inside that call.
- Container snapshots:
	- FreePBX (Asterisk aggregates, AstDB, queues, transports, sender presence), MariaDB (`mysqlcheck`, localnets, `need_reload`) and nethvoice-proxy (dispatcher, RTPengine) data are collected with one `podman exec`/`runagent` call each. Sections start with `<random marker> <name> <exit status>`; consumers distinguish command failure (non-zero or missing section) from empty results. Reduce identities to counts inside the container.
- Parallel queries:
	- `start_query <name> <command...>` runs read-only commands in the background (at most `MAX_PARALLEL_QUERIES`) into a temporary directory; `fetch_query <name>` waits and returns exact output and status. Module contexts, container/service queries, snapshots, the journal scan, `podman system df`, `needs-restarting` and leftover-home `du` run this way. Without a work directory (e.g. in tests), consumers run inline.

### NS8 module/version naming practices

- `IMAGE_URL` is parsed as registry source + tag (`source:version`) to identify installed module version.
- GitHub repository inference follows NS8 naming convention:
	- `<org>/ns8-<module-name>` (e.g. `nethserver/ns8-traefik`, `nethesis/ns8-nethvoice`).
- Module selection uses NS8 module IDs/names from Redis inventory (e.g., `traefik`, `samba`, `mail`, `crowdsec`, `nethvoice`).

### NS8 cluster behavior assumption used

- Worker-node Redis is treated as a replica of leader data, so read-only queries on `cluster/*`, `module/*`, and `node/*` keys are expected to work on both leader and worker nodes.

## Configurable constants

- `LOG_SCAN_MAX_BYTES=1048576` — Maximum bytes in the active log tail.
- `LOG_SCAN_MAX_LINES=20000` — Maximum lines within that tail; also the journal entry limit.
- `LOG_SIZE_WARNING_BYTES=1073741824` — Active `/var/log/messages` size warning threshold.
- `JOURNAL_SCAN_HOURS=24` — Error-priority journal window.
- `JOURNAL_NOISY_SOURCE_COUNT=1000` — Per-source journal error count that warns.
- `RESTART_THRESHOLD=5` — Container restart problem threshold; service restart warning threshold (problem when repeatedly auto-restarting).
- `RESTART_RECENT_SECONDS=86400` — Units stable for longer than this report high restart counts as informational.
- `RUNAGENT_TIMEOUT=15` — Seconds for each module-context `runagent` query.
- `FS_WARNING_PCT=85` / `FS_PROBLEM_PCT=95` — Filesystem block and inode usage thresholds (root and module-home filesystems).
- `NV_CHANNEL_MAX_AGE=14400` — Asterisk channel age (seconds) that warns.
- `WG_HANDSHAKE_MAX_AGE=300` — WireGuard handshake age (seconds) that flags an unreachable node.
- `BACKUP_AGE_GRACE_SECONDS=3600` — Slack added to twice the backup interval.
- `PODMAN_RECLAIMABLE_WARNING_BYTES=10000000000` — Reclaimable rootful image size that warns.
- `SUBSCRIPTION_EXPIRY_WARNING_DAYS=30` — Subscription expiry warning window.
- `MAX_PARALLEL_QUERIES=8` — Background query concurrency.
- `MEMORY_WARNING_PCT=90` — Effective memory usage warning threshold.
- `MEMORY_PROBLEM_PCT=95` — Effective memory usage problem threshold.
- `DNS_SLOW_MS=2000` — DNS resolution time (ms) above which a problem is flagged.
- `QUEUE_RINGALL_MAX_QUEUES=3` — Ringall queue count above which a warning is flagged.
- `QUEUE_RINGALL_MAX_AGENTS=5` — Agent count in a ringall queue above which a warning is flagged.

## Arguments

- `-s`, `--silent` — Suppress OK and most INFO messages.
- `--json` — Print a JSON report (`node_id`, `cluster_role`, counts, `problems`, `warnings`) on stdout; human-readable output goes to stderr. The exit code is unchanged.
- `--offline` — Skip external lookups and active probes: public IP services, GitHub, TLS handshakes, hairpin NAT, `list-updates`/`list-core-modules` and `get-subscription`. The public IP falls back to a local nethvoice-proxy `PUBLIC_IP` for display.
- `--worker` — Parsed for compatibility; the role is detected automatically and worker-specific checks run on worker nodes.

## Code structure

- All checks are functions defined before the source guard; the guard is followed only by `main "$@"`, so tests can source the script and call any check.

# how to test the code

Run local regression tests without a live NS8 node:

```bash
bash -n sysanal3
bash tests/test_module_paths.sh
bash tests/test_diagnostics.sh
bash tests/test_log_scans.sh
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck sysanal3 tests/test_module_paths.sh tests/test_diagnostics.sh tests/test_log_scans.sh
fi
```

The suite sources only helper definitions and uses `mktemp -d` fixtures plus
mocked runtime, NSS, filesystem, and listener commands. Fixture `home` and `home2`
directories must stay under the temporary directory. Do not create real home
entries, source environment files, or disclose fixture secret canaries.

Makako is a test machine that can be used to test the `sysanal3` script. You can access it via SSH:
```
ssh makako.sf.nethserver.net
```
and copy the script to the machine for testing with scp
