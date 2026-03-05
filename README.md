# sysanal3

**NethServer 8 System Analyzer** — Analyzes a NethServer 8 system and automatically searches for known issues.

## Quick Start

Run as **root** on a NethServer 8 node:

```bash
bash <(curl -sfL https://raw.githubusercontent.com/Stell0/sysanal3/main/sysanal3)
```

## What it does

The script executes a series of automated checks and reports all detected **problems** and **warnings**.

### Checks performed

- **Internet connectivity precheck** — Pings `sos.nethesis.it`; if unreachable, GitHub version checks are skipped.
- **General System Data** — IP addresses, DNS nameservers, hostname/FQDN, open file descriptors, root filesystem usage, uptime, timezone, cluster subscription `system_id` (warns if missing), cluster UUID.
- **Long-running sngrep** — Flags `sngrep` processes running for more than 1 day.
- **Module inventory** — Lists all modules installed on the node.
- **Module version check** — Compares installed module versions against the latest GitHub release (skipped without internet).
- **Per-module container health** — Runs `podman ps -a` for each module. Flags containers in Created/Exited/Paused state (warning) and containers with >5 restarts (problem).
- **Failed services** — Checks for system-wide and per-module failed systemd services.
- **Dead/inactive services** — Detects user services in `dead` or `inactive` state.
- **NethVoice-specific checks**:
  - DNS resolution via `getent hosts ibm.com`.
  - MySQL integrity via `mysqlcheck`.
  - Asterisk PJSIP contacts count (warns if zero while Asterisk is running).
- **Listening ports** — Verifies expected ports are in LISTEN state for installed services (Traefik 80/443, NethVoice 5060/5061, Samba 389/636, Mail 25/143/993).
- **CrowdSec** — If present, checks whether any local IP is blocked.
- **Multi-node support** — On the leader node, SSHes into each worker and re-runs itself with `--worker`.

## Arguments

| Flag | Description |
|------|-------------|
| `--worker` | Indicates the script is running remotely on a worker node (skips re-SSHing into workers). |

## Configurable constants

| Constant | Default | Description |
|----------|---------|-------------|
| `RESTART_THRESHOLD` | `5` | Container restart count above which a problem is flagged. |
| `DNS_SLOW_MS` | `2000` | DNS resolution time (ms) above which a problem is flagged. |

## References

- [NethServer 8 Developer Manual](https://nethserver.github.io/ns8-core/)
- [NethServer 8 Administrator Manual](https://docs.nethserver.org/projects/ns8/en/latest/)

## License

See the [repository](https://github.com/Stell0/sysanal3) for license details.
