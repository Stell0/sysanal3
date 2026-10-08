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

- **Internet connectivity precheck**: `ping -qc 1 -W 3 sos.nethesis.it`. If unreachable, GitHub version checks are skipped.
- **General System Data**: IP addresses, DNS nameservers, hostname/FQDN, open file descriptors, root filesystem usage, usage of filesystems containing local module homes (shared mounts reported once, excluding the already reported root filesystem), available memory and swap usage, CPU load average (warns if 1-minute load is above the core count, problem if above 2x the core count), uptime, timezone, cluster subscription `system_id` (warns if missing), cluster UUID.
- **Bounded log scans**: Scan the last `LOG_SCAN_MAX_BYTES=1048576` bytes and at most `LOG_SCAN_MAX_LINES=20000` lines of `/var/log/messages` and the active Asterisk full log in a single pass with a 15-second timeout. Print matching pattern names only, never raw log records. Do not scan rotated archives by default; older history requires a separate scoped investigation.
- Check for `sngrep` instances running for more than 1 day.
- List all modules in this node.
- For all modules, check if the installed version is older than the latest released version (latest release from GitHub). Skipped if no internet.
- **Per-module container health**: Use `podman ps -a` for IDs/names and selected `podman inspect --format` fields for state, restart count, OOM and health status. Flag stopped/paused containers, excess restarts, dead containers, OOM kills and unhealthy containers. Rootful Podman is shared: inspect only names equal to the module ID or beginning with `<module-id>-`. Show `TRAEFIK_HOST` if set.
- Check system-wide failed services and module-owned services in the appropriate systemd manager.
- **Module service expectations**: Use `systemctl show` properties (`Id`, `Type`, `LoadState`, `ActiveState`, `SubState`, `UnitFileState`, `Result`, `NRestarts`, `TriggeredBy`, `ConditionResult`). Enabled inactive daemons warn; successful oneshots, disabled features, triggered services and unmet conditions may be inactive. Failed services and repeated auto-restart state above the threshold are problems; other high historical restart counts warn and require correlation with recent logs.
- **Node memory pressure**: Use `/proc/meminfo` `MemAvailable` rather than free memory alone; warn at 90% used, flag a problem at 95%, and show memory/swap totals even with `--silent`. Missing measurements are warnings, not exhaustion findings.
- For all NethVoice modules:
	- Check DNS by running `getent hosts ibm.com`.
	- Run `mysqlcheck`.
	- **MariaDB `asterisk.kvstore_Sipsettings` localnets**: Flags a problem if a `localnets` row exists.
	- **FreePBX email sender**: Warns if neither `SMTP_FROM_ADDRESS=...` in the `freepbx` container nor `/etc/asterisk/voicemail.conf` `mailcmd=/var/lib/asterisk/bin/send_email -f ...` is configured.
	- **Asterisk runtime**: Query `core show version`, `core show uptime seconds`, and `core show channels count`; print only version, uptime/reload age and aggregate counts. Preserve command failure versus zero counts.
	- **Asterisk PJSIP contacts**: Parse `Objects found` inside the container, without returning contact URIs. Warn if zero and the CLI is running.
	- **Asterisk AstDB AMPUSER cidname**: Warns if an entry with empty extension exists, such as `/AMPUSER//cidname`, and suggests running `database del AMPUSER/ cidname` in the Asterisk CLI.
	- **Asterisk AstDB call forward (CF)**: Warns for each extension that has `CF` enabled and flags circular call forward chains as problems.
	- **Asterisk queue ring strategy**: Warns if more than 3 queues use `ringall`, or if any `ringall` queue has more than 5 agents.
	- Validate NethVoice `*PORT*` environment variables against listening processes (Asterisk/Kamailio ownership checks).
	- Verify expected Asterisk listening ports, enforce that Asterisk is not listening on `5060`/`5061`, and verify PJSIP transport alignment with `ASTERISK_SIP_PORT`.
- **Listening ports**: For installed services, verifies ports are in LISTEN state (Traefik 80/443, Samba 389/636, Mail 25/143/993). For NethVoice, uses module environment values (`PROXY_PORT`, `ASTERISK_SIP_PORT`, optional `ASTERISK_SIP_UDP_PORT`, `ASTERISK_SIPS_PORT`) and validates process ownership.
- If CrowdSec is present (warning):
	- Check whether any network interface IP is blocked.
	- Example command: `cscli decisions list -i "1.2.3.4" -o raw`.
- **Node context info**: Detects local node ID and reports leader/non-leader status and total node count.

## NethServer 8-specific commands and practices used

### NS8 command usage

- `runagent -m <module-id> ...`
	- Core NS8 module-context execution primitive used throughout the script.
	- Used to run module-scoped `podman`, `systemctl --user`, and in-container checks (`podman exec`).
- `redis-cli --raw ...` against NS8 Redis keyspace
	- Used to read cluster and module metadata from NS8 control-plane data.

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
	- Enumerated with `KEYS 'node/*/vpn'` to derive total node count.

### NS8 filesystem and runtime conventions

- Node identity files:
	- `/var/lib/nethserver/node/state/environment` (reads `NODE_ID`).
	- `/var/lib/nethserver/node/state/agent.env` (fallback from `AGENT_ID=node/<id>`).
- Module state environment file:
	- Resolve once per local module with `timeout 5s runagent -m <module-id> printenv AGENT_STATE_DIR </dev/null 2>/dev/null`; require successful status and one nonempty absolute directory path, then append `/environment`.
	- If runtime discovery fails or is invalid, use `getent passwd <module-id> </dev/null 2>/dev/null`, validate the matching account name, and read home field 6. The fallback is `<account-home>/.config/state/environment`.
	- Relocated homes, paths with spaces, and custom rootful state directories without Unix accounts are supported; do not assume `/home` or `/home2` or change the analyzer's `HOME`.
	- A valid runtime directory is authoritative even if its environment file is missing or unreadable. Require a regular, readable file and never silently use a stale fallback.
	- Cache successes and failures in the parent Bash process. Emit one actionable warning per failed module, skip environment-dependent checks, and continue independent diagnostics. Do not call `warning()` inside path-returning command substitutions.
	- Read targeted values only; never source/eval environment files or print their full contents or credentials.
	- Reused by `TRAEFIK_HOST` reporting, configured port auditing, proxy certificates, NethVoice certificates/routes/Asterisk alignment, and NethVoice listening-port checks.
- Module home filesystem reporting:
	- Use NSS-resolved local homes with `findmnt -n -o TARGET --target <home>` and quoted `df -P -- <home>` / `df -h -- <home>`.
	- Report each shared mount once after module discovery and avoid repeating root. Keep the 90% problem threshold and visibility with `--silent`.
- Per-module systemd context:
	- Cache `timeout 5s runagent -m <id> id -u` to distinguish rootless/rootful execution; never infer context solely from an NSS account.
	- Rootless services use `runagent -m <id> systemctl --user show ...`; rootful services use the system manager scoped to `<id>.service` and `<id>-*.service`.
	- Runtime queries use bounded timeouts, detached stdin, selected properties, and fixed failure messages instead of raw stderr.
- NethVoice proxy address:
	- Route checks prefer targeted `PROXY_IP` from the resolved environment and verify node-local address ownership, with `wg0` fallback for older environments and bracketed IPv6 destinations. Use `ASTERISK_SIP_UDP_PORT` when defined, falling back to `ASTERISK_SIP_PORT` only for older shared-port versions; malformed UDP values must not fall back to TCP. Check separately allocated UDP listeners with UDP socket queries.
- Per-module container model:
	- Module containers are queried with `runagent -m <id> podman ...`.

### NS8 module/version naming practices

- `IMAGE_URL` is parsed as registry source + tag (`source:version`) to identify installed module version.
- GitHub repository inference follows NS8 naming convention:
	- `<org>/ns8-<module-name>` (e.g. `nethserver/ns8-traefik`, `nethesis/ns8-nethvoice`).
- Module selection uses NS8 module IDs/names from Redis inventory (e.g., `traefik`, `samba`, `mail`, `crowdsec`, `nethvoice`).

### NS8 cluster behavior assumption used

- Worker-node Redis is treated as a replica of leader data, so read-only queries on `cluster/*`, `module/*`, and `node/*` keys are expected to work on both leader and worker nodes.

## Configurable constants

- `LOG_SCAN_MAX_BYTES=1048576` — Maximum bytes in the active log tail.
- `LOG_SCAN_MAX_LINES=20000` — Maximum lines within that tail.
- `RESTART_THRESHOLD=5` — Container restart problem threshold; service restart warning threshold (problem when repeatedly auto-restarting).
- `MEMORY_WARNING_PCT=90` — Effective memory usage warning threshold.
- `MEMORY_PROBLEM_PCT=95` — Effective memory usage problem threshold.
- `DNS_SLOW_MS=2000` — DNS resolution time (ms) above which a problem is flagged.
- `QUEUE_RINGALL_MAX_QUEUES=3` — Ringall queue count above which a warning is flagged.
- `QUEUE_RINGALL_MAX_AGENTS=5` — Agent count in a ringall queue above which a warning is flagged.

## Arguments

- `--worker` — Parsed for compatibility; currently does not change check flow in this script version.

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
