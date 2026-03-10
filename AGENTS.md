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
- **General System Data**: IP addresses, DNS nameservers, hostname/FQDN, open file descriptors, root filesystem usage, CPU load average (warns if 1-minute load is above the core count, problem if above 2x the core count), uptime, timezone, cluster subscription `system_id` (warns if missing), cluster UUID.
- Check for `sngrep` instances running for more than 1 day.
- List all modules in this node.
- For all modules, check if the installed version is older than the latest released version (latest release from GitHub). Skipped if no internet.
- **Per-module container health**: `podman ps -a` for each module. Flags containers in Created/Exited/Paused state (warning) and containers with >5 restarts (problem). Shows `TRAEFIK_HOST` if set.
- Check if there are services in failed state (system-wide and per-module).
- **Per-module dead/inactive services**: Detects user services in `dead` or `inactive` state (not just `failed`).
- For all NethVoice modules:
	- Check DNS by running `getent hosts ibm.com`.
	- Run `mysqlcheck`.
	- **Asterisk PJSIP contacts**: Counts registered PJSIP contacts. Warns if zero and Asterisk is running.
	- **Asterisk AstDB call forward (CF)**: Warns for each extension that has `CF` enabled and flags circular call forward chains as problems.
	- **Asterisk queue ring strategy**: Warns if more than 3 queues use `ringall`, or if any `ringall` queue has more than 5 agents.
	- Validate NethVoice `*PORT*` environment variables against listening processes (Asterisk/Kamailio ownership checks).
	- Verify expected Asterisk listening ports, enforce that Asterisk is not listening on `5060`/`5061`, and verify PJSIP transport alignment with `ASTERISK_SIP_PORT`.
- **Listening ports**: For installed services, verifies ports are in LISTEN state (Traefik 80/443, Samba 389/636, Mail 25/143/993). For NethVoice, uses module environment values (`PROXY_PORT`, `ASTERISK_SIP_PORT`, `ASTERISK_SIPS_PORT`) and validates process ownership.
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
- `node/1/vpn` (hash)
	- Field used: `endpoint` (`HGET node/1/vpn endpoint`) for leader-node endpoint info.
- `node/*/vpn` keys pattern
	- Enumerated with `KEYS 'node/*/vpn'` to derive total node count.

### NS8 filesystem and runtime conventions

- Node identity files:
	- `/var/lib/nethserver/node/state/environment` (reads `NODE_ID`).
	- `/var/lib/nethserver/node/state/agent.env` (fallback from `AGENT_ID=node/<id>`).
- Module state environment file:
	- `/home/<module-id>/.config/state/environment`.
	- Used for module variables such as `TRAEFIK_HOST` and NethVoice `*PORT*` variables.
- Per-module user-systemd model:
	- Module services are checked with `runagent -m <id> systemctl --user ...`.
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

- `RESTART_THRESHOLD=5` — Container restart count above which a problem is flagged.
- `DNS_SLOW_MS=2000` — DNS resolution time (ms) above which a problem is flagged.
- `QUEUE_RINGALL_MAX_QUEUES=3` — Ringall queue count above which a warning is flagged.
- `QUEUE_RINGALL_MAX_AGENTS=5` — Agent count in a ringall queue above which a warning is flagged.

## Arguments

- `--worker` — Parsed for compatibility; currently does not change check flow in this script version.

# how to test the code
Makako is a test machine that can be used to test the `sysanal3` script. You can access it via SSH:
```
ssh makako.sf.nethserver.net
```
and copy the script to the machine for testing with scp
