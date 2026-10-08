#!/bin/bash
# The sourced analyzer returns before main; ShellCheck follows its direct-run exits.
# shellcheck disable=SC2317,SC2329
# Passive diagnostic regressions. No NS8 node or active network probes are needed.
set -uo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixture_root=$(mktemp -d)
trap 'rm -rf -- "$fixture_root"' EXIT
export DIAGNOSTIC_FIXTURES="$fixture_root"
mkdir "$fixture_root/bin"
export PATH="$fixture_root/bin:$PATH"
cat > "$fixture_root/bin/runagent" <<'MOCK'
#!/bin/bash
[[ $1 == -m ]] || exit 99
mod=$2
shift 2
if IFS= read -r unexpected; then exit 98; fi
printf '%s %s\n' "$mod" "$*" >> "$DIAGNOSTIC_FIXTURES/calls"
case "$1" in
    id)
        [[ $# == 2 && $2 == -u ]] || exit 99
        [[ -f "$DIAGNOSTIC_FIXTURES/$mod.uid" ]] || exit 1
        cat "$DIAGNOSTIC_FIXTURES/$mod.uid"
        ;;
    systemctl)
        if [[ "$mod" == rootful ]]; then
            [[ "$*" != *--user* && "$*" == *'rootful.service rootful-*.service'* ]] || exit 99
        else
            [[ "$2" == --user ]] || exit 99
        fi
        [[ -f "$DIAGNOSTIC_FIXTURES/$mod.services" ]] || exit 1
        cat "$DIAGNOSTIC_FIXTURES/$mod.services"
        ;;
    podman)
        case "$2" in
            ps)
                [[ "$*" == 'podman ps -a --format {{.ID}}|{{.Names}}' ]] || exit 99
                [[ -f "$DIAGNOSTIC_FIXTURES/$mod.ids" ]] || exit 1
                cat "$DIAGNOSTIC_FIXTURES/$mod.ids"
                ;;
            inspect)
                [[ "$3" == --format && "$4" == *'.RestartCount'* && "$4" == *'.State.Healthcheck.Status'* && "$5" == -- ]] || exit 99
                [[ "$4" != *'.Config'* ]] || exit 99
                [[ -f "$DIAGNOSTIC_FIXTURES/$mod.containers" ]] || exit 1
                cat "$DIAGNOSTIC_FIXTURES/$mod.containers"
                ;;
            exec)
                [[ "$3" == freepbx ]] || exit 99
                if [[ "$4" == sh ]]; then
                    shift 3
                    exec "$@"
                fi
                [[ "$4" == asterisk && "$5" == -rx ]] || exit 99
                case "$6" in
                    'core show version') stage=version ;;
                    'core show uptime seconds') stage=uptime ;;
                    'core show channels count') stage=channels ;;
                    *) exit 99 ;;
                esac
                [[ -f "$DIAGNOSTIC_FIXTURES/$stage" ]] || exit 1
                cat "$DIAGNOSTIC_FIXTURES/$stage"
                ;;
        esac
        ;;
    *) exit 99 ;;
esac
MOCK
cat > "$fixture_root/bin/asterisk" <<'MOCK'
#!/bin/bash
[[ $# == 2 && $1 == -rx && $2 == 'pjsip show contacts' ]] || exit 99
cat "$DIAGNOSTIC_FIXTURES/contacts"
exit "$(cat "$DIAGNOSTIC_FIXTURES/contacts.rc")"
MOCK
chmod +x "$fixture_root/bin/"*
# shellcheck source=sysanal3
source "$repo_dir/sysanal3"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3 (expected '$2', got '$1')"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3"; }
reset_messages() { WARNINGS=0; PROBLEMS=0; WARNING_MSGS=(); PROBLEM_MSGS=(); }

printf '1026\n' > "$fixture_root/rootless.uid"
printf '0\n' > "$fixture_root/rootful.uid"
cat > "$fixture_root/rootless.services" <<'DATA'
Id=healthy.service
Type=simple
LoadState=loaded
ActiveState=active
SubState=running
UnitFileState=enabled
Result=success
NRestarts=5

Id=cleanup.service
Type=oneshot
LoadState=loaded
ActiveState=inactive
UnitFileState=enabled
Result=success

Id=timer-job.service
Type=simple
LoadState=loaded
ActiveState=inactive
UnitFileState=enabled
TriggeredBy=timer-job.timer

Id=socket-job.service
Type=simple
LoadState=loaded
ActiveState=inactive
UnitFileState=enabled
TriggeredBy=socket-job.socket

Id=optional.service
Type=forking
LoadState=loaded
ActiveState=inactive
UnitFileState=disabled

Id=wizard-gated.service
Type=forking
LoadState=loaded
ActiveState=inactive
UnitFileState=enabled
ConditionResult=no

Id=masked.service
Type=simple
LoadState=masked
ActiveState=inactive
UnitFileState=enabled
DATA
check_module_services rootless > "$fixture_root/output"
assert_eq "$WARNINGS" 0 'conditional, masked and successful oneshot services do not warn'
assert_eq "$PROBLEMS" 0 'restart threshold of 5 is allowed'

cat > "$fixture_root/rootful.services" <<'DATA'
Id=rootful.service
Type=simple
LoadState=loaded
ActiveState=active
SubState=running
UnitFileState=enabled
Result=success
NRestarts=0
DATA
check_module_services rootful >> "$fixture_root/output"
check_module_services rootful >> "$fixture_root/output"
assert_eq "$WARNINGS" 0 'rootful system manager is used'
assert_eq "$(grep -cx 'rootful id -u' "$fixture_root/calls")" 1 'execution UID is cached'

cat >> "$fixture_root/rootless.services" <<'DATA'

Id=stopped.service
Type=simple
LoadState=loaded
ActiveState=inactive
UnitFileState=enabled-runtime

Id=failed.service
Type=oneshot
LoadState=loaded
ActiveState=failed
Result=exit-code

Id=restart-loop.service
Type=simple
LoadState=loaded
ActiveState=activating
SubState=auto-restart
NRestarts=6

Id=running-agent.service
Type=simple
LoadState=loaded
ActiveState=active
SubState=running
NRestarts=20
Result=success

Id=failed-cleanup.service
Type=oneshot
LoadState=loaded
ActiveState=inactive
TriggeredBy=failed-cleanup.timer
Result=timeout
DATA
check_module_services rootless >> "$fixture_root/output"
assert_eq "$WARNINGS" 3 'enabled inactive daemon, historical restarts and unsuccessful last run warn'
assert_eq "$PROBLEMS" 2 'failed unit and repeated automatic restarts are detected'
assert_eq "${#WARNING_MSGS[@]}" "$WARNINGS" 'service warning counts stay in parent'
assert_eq "${#PROBLEM_MSGS[@]}" "$PROBLEMS" 'service problem counts stay in parent'
reset_messages
check_module_services missing-uid >> "$fixture_root/output"
check_module_services missing-uid >> "$fixture_root/output"
assert_eq "$WARNINGS" 1 'UID lookup failure is cached and warns once'
printf '1026\n' > "$fixture_root/unavailable.uid"
check_module_services unavailable >> "$fixture_root/output"
assert_eq "$WARNINGS" 2 'failed service query warns instead of implying health'

reset_messages
printf '0123456789ab|freepbx\nabcdef012345|mariadb\n' > "$fixture_root/rootless.ids"
cat > "$fixture_root/rootless.containers" <<'DATA'
/freepbx|running|5|false|healthy
mariadb|running|0|false|
DATA
check_module_containers rootless >> "$fixture_root/output"
assert_eq "$WARNINGS" 0 'healthy containers without a healthcheck are accepted'
assert_eq "$PROBLEMS" 0 'container restart threshold of 5 is allowed'
cat > "$fixture_root/rootless.containers" <<'DATA'
/freepbx|running|6|true|unhealthy
mariadb|exited|0|false|
DATA
check_module_containers rootless >> "$fixture_root/output"
assert_eq "$PROBLEMS" 3 'container restarts, OOM and healthcheck failures detected'
assert_eq "$WARNINGS" 1 'exited container detected'
reset_messages
printf '111111111111|rootful\n222222222222|rootful-worker\n333333333333|unrelated-host-container\n444444444444|rootful2\n' > "$fixture_root/rootful.ids"
printf 'rootful|running|0|false|healthy\nrootful-worker|running|0|false|\n' > "$fixture_root/rootful.containers"
check_module_containers rootful >> "$fixture_root/output"
assert_eq "$WARNINGS" 0 'rootful module containers are accepted'
assert_contains "$(grep 'rootful podman inspect' "$fixture_root/calls")" '-- 111111111111 222222222222' 'rootful inspection selects only module-owned containers'
[[ $(grep 'rootful podman inspect' "$fixture_root/calls") != *333333333333* && $(grep 'rootful podman inspect' "$fixture_root/calls") != *444444444444* ]] || fail 'rootful inventory includes other modules or host containers'

reset_messages
printf '1026\n' > "$fixture_root/bad.uid"
printf 'canary-invalid-id\n' > "$fixture_root/bad.ids"
check_module_containers bad >> "$fixture_root/output"
assert_eq "$WARNINGS" 1 'malformed container inventory rejected'
check_module_containers unavailable >> "$fixture_root/output"
assert_eq "$WARNINGS" 2 'failed container query warns'
printf '1026\n' > "$fixture_root/empty.uid"
printf '' > "$fixture_root/empty.ids"
check_module_containers empty >> "$fixture_root/output"
assert_eq "$WARNINGS" 2 'modules without containers are allowed'

memory_fixture() {
    printf 'MemTotal: 1000 kB\nMemAvailable: %s kB\nSwapTotal: 100 kB\nSwapFree: 75 kB\n' "$1" > "$fixture_root/meminfo"
}
reset_messages
SILENT=1
memory_fixture 110
check_node_memory "$fixture_root/meminfo" > "$fixture_root/memory-output"
assert_eq "$WARNINGS" 0 '89 percent effective memory usage is allowed'
assert_contains "$(cat "$fixture_root/memory-output")" '25 KiB used / 100 KiB total' 'swap reporting remains visible in silent mode'
memory_fixture 100
check_node_memory "$fixture_root/meminfo" >> "$fixture_root/memory-output"
assert_eq "$WARNINGS" 1 '90 percent memory warns'
memory_fixture 50
check_node_memory "$fixture_root/meminfo" >> "$fixture_root/memory-output"
assert_eq "$PROBLEMS" 1 '95 percent memory is a problem'
printf 'MemTotal: 1000 kB\n' > "$fixture_root/meminfo"
check_node_memory "$fixture_root/meminfo" >> "$fixture_root/memory-output"
assert_eq "$WARNINGS" 2 'missing available-memory data warns'
assert_eq "$PROBLEMS" 1 'missing memory data is not a false exhaustion problem'

reset_messages
SILENT=0
printf 'Asterisk 18.26.3 built by IDENTIFIER_CANARY\n' > "$fixture_root/version"
printf 'System uptime: 70000\nLast reload: 60000\n' > "$fixture_root/uptime"
printf '2 active channels\n1 active call\n99 calls processed\n' > "$fixture_root/channels"
check_nethvoice_asterisk_runtime rootless >> "$fixture_root/output"
assert_eq "$WARNINGS" 0 'Asterisk aggregate queries parse successfully'
assert_contains "$(cat "$fixture_root/output")" 'active channels: 2, active calls: 1' 'aggregate calls and channels reported'
printf 'malformed SECRET_CANARY\n' > "$fixture_root/channels"
check_nethvoice_asterisk_runtime rootless >> "$fixture_root/output"
assert_eq "$WARNINGS" 1 'malformed aggregate data warns without disclosure'
rm "$fixture_root/version"
check_nethvoice_asterisk_runtime rootless >> "$fixture_root/output"
assert_eq "$WARNINGS" 2 'unavailable Asterisk is distinguished from zero calls'

reset_messages
printf 'Contact: SIP_IDENTITY_CANARY/sip:private-device\nObjects found: 12\n' > "$fixture_root/contacts"
printf '0\n' > "$fixture_root/contacts.rc"
check_nethvoice_pjsip_contacts rootless >> "$fixture_root/output"
assert_eq "$WARNINGS" 0 'PJSIP summary count is used instead of contact-row heuristics'
assert_contains "$(cat "$fixture_root/output")" 'PJSIP contact objects: 12' 'contact count reported'
printf 'Objects found: 0\n' > "$fixture_root/contacts"
check_nethvoice_pjsip_contacts rootless >> "$fixture_root/output"
assert_eq "$WARNINGS" 1 'zero contacts while CLI is running warn'
printf '1\n' > "$fixture_root/contacts.rc"
check_nethvoice_pjsip_contacts rootless >> "$fixture_root/output"
assert_eq "$WARNINGS" 2 'failed CLI output is not treated as zero contacts'
assert_contains "${WARNING_MSGS[-1]}" 'cannot retrieve' 'failure warning distinguishes unavailable CLI'

# Proxy route validation uses the configured node-local address, including IPv6.
reset_messages
MODULE_PATH_STATUS[voice]=0
MODULE_ENV_FILES[voice]="$fixture_root/environment"
LOCAL_IPS_ARRAY=(10.5.4.1 192.0.2.2 2001:db8::2)
LOCAL_VPN_ADDRESS=10.5.4.1
NETHVOICE_PROXY_ROUTE_COUNT=1
NETHVOICE_PROXY_DOMAIN_SOURCE_MAP[voice.example.test]=proxy
route_fixture() {
    printf 'NETHVOICE_HOST=voice.example.test\nASTERISK_SIP_PORT=15062\nPROXY_IP=%s\n' "$1" > "$fixture_root/environment"
    NETHVOICE_PROXY_DOMAIN_URI_MAP[voice.example.test]="$2"
}
route_fixture 192.0.2.2 sip:192.0.2.2:15062
check_nethvoice_proxy_domain_uri voice >> "$fixture_root/output"
assert_eq "$PROBLEMS" 0 'configured local proxy address overrides wg0'
route_fixture 192.0.2.2 sip:192.0.2.2:24005
printf 'ASTERISK_SIP_UDP_PORT=24005\n' >> "$fixture_root/environment"
check_nethvoice_proxy_domain_uri voice >> "$fixture_root/output"
assert_eq "$PROBLEMS" 0 'split SIP UDP port is used for the proxy route'
assert_eq "$(get_whitelist_port_expected_service ASTERISK_SIP_UDP_PORT)" asterisk 'split UDP port ownership mapping'

route_fixture 2001:db8::2 'sip:[2001:db8::2]:15062'
check_nethvoice_proxy_domain_uri voice >> "$fixture_root/output"
assert_eq "$PROBLEMS" 0 'IPv6 route is bracketed'
route_fixture 192.0.2.2 sip:192.0.2.2:15062
printf 'ASTERISK_SIP_UDP_PORT=malformed\n' >> "$fixture_root/environment"
check_nethvoice_proxy_domain_uri voice >> "$fixture_root/output"
assert_eq "$WARNINGS" 1 'invalid split UDP port warns without reverting to TCP'

route_fixture '' sip:10.5.4.1:15062
check_nethvoice_proxy_domain_uri voice >> "$fixture_root/output"
assert_eq "$PROBLEMS" 0 'older environments retain the wg0 fallback'
route_fixture 198.51.100.20 sip:198.51.100.20:15062
check_nethvoice_proxy_domain_uri voice >> "$fixture_root/output"
assert_eq "$PROBLEMS" 1 'remote proxy address is detected'

# A TCP listener cannot satisfy an explicitly required UDP listener.
cat > "$fixture_root/bin/ss" <<'MOCK'
#!/bin/bash
if [[ $2 == -ltnp || -f "$DIAGNOSTIC_FIXTURES/udp-listener" ]]; then
    printf 'LISTEN 0 128 0.0.0.0:24005 0.0.0.0:* users:(("asterisk",pid=1,fd=1))\n'
fi
MOCK
chmod +x "$fixture_root/bin/ss"
reset_messages
check_port_owner 'split SIP UDP' 24005 '(^| )asterisk( |$)' asterisk udp >> "$fixture_root/output"
assert_eq "$PROBLEMS" 1 'TCP listener alone fails UDP ownership check'
touch "$fixture_root/udp-listener"
check_port_owner 'split SIP UDP' 24005 '(^| )asterisk( |$)' asterisk udp >> "$fixture_root/output"
assert_eq "$PROBLEMS" 1 'actual UDP listener passes'

if grep -Eq 'SECRET_CANARY|IDENTIFIER_CANARY|SIP_IDENTITY_CANARY' "$fixture_root/output" "$fixture_root/memory-output"; then
    fail 'raw command metadata or contact identities disclosed'
fi
printf 'PASS: service contexts, conditional units, container health, memory, Asterisk aggregates, proxy addresses\n'
