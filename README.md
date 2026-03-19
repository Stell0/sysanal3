# sysanal3

**NethServer 8 System Analyzer V3** — Analyzes a NethServer 8 system and automatically searches for known issues.

## Quick Start

Run as **root** on a NethServer 8 node:

```bash
bash <(curl -sfL https://raw.githubusercontent.com/Stell0/sysanal3/main/sysanal3)
```

Run in silent mode to suppress `OK` messages and most `INFO` messages while still printing the full **General System Data** section:

```bash
bash <(curl -sfL https://raw.githubusercontent.com/Stell0/sysanal3/main/sysanal3) -- --silent
```

## What it does

The script executes a series of automated checks and reports all detected **problems** and **warnings**.
It exits with code `1` if any problem is found, otherwise `0`.

### Checks performed

- **Internet connectivity precheck** — Pings `sos.nethesis.it`; if unreachable, GitHub version checks are skipped.
- **General System Data** — IP addresses, DNS nameservers, hostname/FQDN, open file descriptors, root filesystem usage, `/home` filesystem usage when `/home` is a separate mount, CPU load average (warns if 1-minute load is above the core count, problem if above $2\times$ the core count), uptime, timezone, cluster subscription `system_id` (warns if missing), cluster UUID.
- **Long-running sngrep** — Flags `sngrep` processes running for more than 1 day.
- **Module inventory** — Lists all modules installed on the node.
- **Module version check** — Compares installed module versions against the latest GitHub release (skipped without internet).
- **Per-module container health** — Runs `podman ps -a` for each module. Flags containers in Created/Exited/Paused state (warning) and containers with >5 restarts (problem).
- **Failed services** — Checks for system-wide and per-module failed systemd services.
- **Dead/inactive services** — Detects user services in `dead` or `inactive` state.
- **NethVoice-specific checks**:
  - DNS resolution via `getent hosts ibm.com`.
  - MySQL integrity via `mysqlcheck`.
  - MariaDB `asterisk.kvstore_Sipsettings` `localnets` check (problem if a `localnets` row exists).
  - FreePBX email sender check (warns if neither `SMTP_FROM_ADDRESS` nor `voicemail.conf` `mailcmd=...send_email -f ...` is configured).
  - Validates the certificate presented by each local `nethvoice-proxy` `KML_DEFAULT_FQDN` on ports `443` and `5061` (TLS handshake, hostname match, non-expired certificate).
  - Collects domain-to-URI routes from local `nethvoice-proxy` modules and verifies that each instance `NETHVOICE_HOST` points to `sip:<wg0 IPv4>:<ASTERISK_SIP_PORT>`.
  - Validates the certificate presented by each instance `NETHVOICE_HOST` on port `443` (TLS handshake, hostname match, non-expired certificate).
  - Asterisk PJSIP contacts count (warns if zero while Asterisk is running).
  - AstDB call forward check (warns for each extension with `CF` enabled and flags circular forwarding chains as problems).
  - Asterisk queue ring strategy check (warns if more than 3 queues use `ringall`, or any `ringall` queue has more than 5 agents).
  - Validates NethVoice `*PORT*` environment variables against listening processes (e.g. Asterisk/Kamailio ownership checks).
  - Verifies Asterisk expected listening ports, enforces that Asterisk is not listening on `5060`/`5061`, and checks PJSIP transport port alignment.
- **Listening ports** — Verifies expected ports are in LISTEN state for installed services (Traefik 80/443, Samba 389/636, Mail 25/143/993) and checks NethVoice SIP/SIPS ports from module environment (`PROXY_PORT`, `ASTERISK_SIP_PORT`, `ASTERISK_SIPS_PORT`) with process-owner validation.
- **CrowdSec** — If present, checks whether any local IP is blocked.

The certificate checks require `openssl` to be available on the host. If `openssl` is missing, the script reports that the related certificate checks were skipped.

## Arguments

| Flag | Description |
|------|-------------|
| `-s`, `--silent` | Suppress `OK` messages and most `INFO` messages. Warnings, problems, headers, the full General System Data section, and the final summary are still printed. |
| `--worker` | Parsed for compatibility; currently does not change check flow in this script version. |

## Configurable constants

| Constant | Default | Description |
|----------|---------|-------------|
| `RESTART_THRESHOLD` | `5` | Container restart count above which a problem is flagged. |
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
