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
    sh)
        # Module-context scripts run locally against the mocked tools below.
        export MOCK_MODULE="$mod" AGENT_STATE_DIR=/state
        exec "$@"
        ;;
    systemctl)
        if [[ "$mod" == rootful ]]; then
            [[ "$*" != *--user* && "$*" == *'rootful.service rootful-*.service'* ]] || exit 99
        else
            [[ "$2" == --user ]] || exit 99
        fi
        [[ "$*" == *ActiveEnterTimestampMonotonic* ]] || exit 99
        [[ -f "$DIAGNOSTIC_FIXTURES/$mod.services" ]] || exit 1
        cat "$DIAGNOSTIC_FIXTURES/$mod.services"
        ;;
    podman)
        [[ "$2" == exec && "$3" == freepbx && "$4" == sh ]] || exit 99
        shift 3
        exec "$@"
        ;;
    *) exit 99 ;;
esac
MOCK
cat > "$fixture_root/bin/id" <<'MOCK'
#!/bin/bash
[[ $# == 1 && $1 == -u && -f "$DIAGNOSTIC_FIXTURES/$MOCK_MODULE.uid" ]] || exit 1
cat "$DIAGNOSTIC_FIXTURES/$MOCK_MODULE.uid"
MOCK
cat > "$fixture_root/bin/podman" <<'MOCK'
#!/bin/bash
printf '%s podman %s\n' "$MOCK_MODULE" "$*" >> "$DIAGNOSTIC_FIXTURES/calls"
case "$1" in
    ps)
        [[ "$*" == 'ps -a --format {{.ID}}|{{.Names}}' ]] || exit 99
        [[ -f "$DIAGNOSTIC_FIXTURES/$MOCK_MODULE.ids" ]] || exit 1
        cat "$DIAGNOSTIC_FIXTURES/$MOCK_MODULE.ids"
        ;;
    inspect)
        [[ "$2" == --format && "$3" == *'.RestartCount'* && "$3" == *'.State.Healthcheck.Status'* && "$4" == -- ]] || exit 99
        [[ "$3" != *'.Config'* ]] || exit 99
        [[ -f "$DIAGNOSTIC_FIXTURES/$MOCK_MODULE.containers" ]] || exit 1
        cat "$DIAGNOSTIC_FIXTURES/$MOCK_MODULE.containers"
        ;;
    *) exit 99 ;;
esac
MOCK
cat > "$fixture_root/bin/asterisk" <<'MOCK'
#!/bin/bash
[[ $# == 2 && $1 == -rx ]] || exit 99
case "$2" in
    'core show version') stage=version ;;
    'core show uptime seconds') stage=uptime ;;
    'core show channels count') stage=channels ;;
    'pjsip show contacts') stage=contacts ;;
    'pjsip show endpoints') stage=endpoints ;;
    'pjsip show registrations') stage=registrations ;;
    'core show channels concise') stage=concise ;;
    *) exit 1 ;;
esac
[[ -f "$DIAGNOSTIC_FIXTURES/$stage" ]] || exit 1
cat "$DIAGNOSTIC_FIXTURES/$stage"
exit "$(cat "$DIAGNOSTIC_FIXTURES/$stage.rc" 2>/dev/null || printf '0')"
MOCK
cat > "$fixture_root/bin/systemctl" <<'MOCK'
#!/bin/bash
[[ "$*" == 'list-units --failed --no-legend --no-pager --plain' ]] || exit 99
cat "$DIAGNOSTIC_FIXTURES/failed-units" 2>/dev/null
MOCK
# Redis keys are files: "<key with / as _>.<field>" or ".scan" pattern lists.
cat > "$fixture_root/bin/redis-cli" <<'MOCK'
#!/bin/bash
[[ $1 == --raw ]] || exit 99
shift
redis="$DIAGNOSTIC_FIXTURES/redis"
if [[ $# == 0 ]]; then
    # Batch mode: one reply line per command read from stdin.
    while read -r cmd key field; do
        case "$cmd" in
            HGET) cat "$redis/${key//\//_}.$field" 2>/dev/null; echo ;;
            SISMEMBER) if [[ -f "$redis/${key//\//_}.$field" ]]; then echo 1; else echo 0; fi ;;
            *) echo ;;
        esac
    done
    exit 0
fi
case "$1" in
    --scan) cat "$redis/${3//\//_}.scan" 2>/dev/null ;;
    HGET) cat "$redis/${2//\//_}.$3" 2>/dev/null ;;
    SISMEMBER) if [[ -f "$redis/${2//\//_}.$3" ]]; then echo 1; else echo 0; fi ;;
    *) exit 99 ;;
esac
MOCK
chmod +x "$fixture_root/bin/"*
# shellcheck source=sysanal3
source "$repo_dir/sysanal3"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
monotonic_now_usec() { printf '200000000000\n'; }
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
assert_eq "$(grep -c '^rootful sh -c id -u' "$fixture_root/calls")" 1 'execution UID is cached'

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

Id=old-burst.service
Type=simple
LoadState=loaded
ActiveState=active
SubState=running
NRestarts=20
Result=success
ActiveEnterTimestampMonotonic=1000000

Id=recent-burst.service
Type=simple
LoadState=loaded
ActiveState=active
SubState=running
NRestarts=20
Result=success
ActiveEnterTimestampMonotonic=199000000000

Id=failed-cleanup.service
Type=oneshot
LoadState=loaded
ActiveState=inactive
TriggeredBy=failed-cleanup.timer
Result=timeout
DATA
check_module_services rootless >> "$fixture_root/output"
assert_eq "$WARNINGS" 4 'enabled inactive daemon, recent or undated restarts and unsuccessful last run warn'
[[ "${WARNING_MSGS[*]}" != *old-burst* ]] || fail 'restart burst followed by a long stable period warns'
assert_contains "${WARNING_MSGS[*]}" 'recent-burst.service has 20 automatic restarts since counter reset, last start 16m ago' 'recent restart burst warns with age'
assert_eq "${MODULE_UNIT_ACTIVE[rootless|stopped.service]}" inactive 'unit states are cached for port checks'
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
forget_snapshot freepbx:rootless
check_nethvoice_asterisk_runtime rootless >> "$fixture_root/output"
assert_eq "$WARNINGS" 0 'Asterisk aggregate queries parse successfully'
assert_contains "$(cat "$fixture_root/output")" 'active channels: 2, active calls: 1' 'aggregate calls and channels reported'
printf 'malformed SECRET_CANARY\n' > "$fixture_root/channels"
forget_snapshot freepbx:rootless
check_nethvoice_asterisk_runtime rootless >> "$fixture_root/output"
assert_eq "$WARNINGS" 1 'malformed aggregate data warns without disclosure'
rm "$fixture_root/version"
forget_snapshot freepbx:rootless
check_nethvoice_asterisk_runtime rootless >> "$fixture_root/output"
assert_eq "$WARNINGS" 2 'unavailable Asterisk is distinguished from zero calls'

reset_messages
printf 'Contact: SIP_IDENTITY_CANARY/sip:private-device\nObjects found: 12\n' > "$fixture_root/contacts"
printf '0\n' > "$fixture_root/contacts.rc"
forget_snapshot freepbx:rootless
check_nethvoice_pjsip_contacts rootless >> "$fixture_root/output"
assert_eq "$WARNINGS" 0 'PJSIP summary count is used instead of contact-row heuristics'
assert_contains "$(cat "$fixture_root/output")" 'PJSIP contact objects: 12' 'contact count reported'
printf 'Objects found: 0\n' > "$fixture_root/contacts"
forget_snapshot freepbx:rootless
check_nethvoice_pjsip_contacts rootless >> "$fixture_root/output"
assert_eq "$WARNINGS" 1 'zero contacts while CLI is running warn'
printf '1\n' > "$fixture_root/contacts.rc"
forget_snapshot freepbx:rootless
check_nethvoice_pjsip_contacts rootless >> "$fixture_root/output"
assert_eq "$WARNINGS" 2 'failed CLI output is not treated as zero contacts'
assert_contains "${WARNING_MSGS[-1]}" 'cannot retrieve' 'failure warning distinguishes unavailable CLI'

# Endpoint, registration and channel data are reduced to counts in the container.
reset_messages
cat > "$fixture_root/endpoints" <<'DATA'
 Endpoint:  <Endpoint/CID.....................................>  <State.....>  <Channels.>
 Endpoint:  201/SIP_IDENTITY_CANARY                              Not in use    0 of inf
 Endpoint:  202/202                                              Unavailable   0 of inf
DATA
cat > "$fixture_root/registrations" <<'DATA'
 <Registration/ServerURI..............................>  <Auth..........>  <Status.......>
 trunk1/sip:SIP_IDENTITY_CANARY.example.test             trunk1            Registered
 trunk2/sip:provider.example.test                        trunk2            Rejected

Objects found: 2
DATA
printf 'SIP/1!ctx!200!1!Up!Dial!x!CUSTOMER_CANARY!!!3!20000!b!u1\nSIP/2!ctx!201!1!Up!Dial!x!y!!!3!60!b!u2\n' > "$fixture_root/concise"
forget_snapshot freepbx:rootless
{
    check_nethvoice_pjsip_endpoints rootless
    check_nethvoice_trunk_registrations rootless
    check_nethvoice_long_channels rootless
} >> "$fixture_root/output"
assert_contains "$(cat "$fixture_root/output")" 'PJSIP endpoints: 2 configured, 1 unavailable' 'endpoint header excluded from counts'
assert_eq "$PROBLEMS" 1 'rejected registration is a problem'
assert_contains "${PROBLEM_MSGS[0]}" '1 of 2 outbound SIP registration' 'registration counts reported'
assert_eq "$WARNINGS" 1 'channel older than the limit warns'
assert_contains "${WARNING_MSGS[0]}" '1 of 2 active channel' 'long channel count reported'

# Restart reporting and failed system units.
reset_messages
printf 'cockpit.service loaded failed failed Cockpit\npromtail.service loaded failed failed Alloy\n' > "$fixture_root/failed-units"
check_failed_system_services >> "$fixture_root/output"
assert_eq "$PROBLEMS" 2 'each failed system unit is a separate problem'
assert_contains "${PROBLEM_MSGS[1]}" 'promtail.service' 'failed unit name is in the summary message'

# WireGuard peers are named by VPN address and judged by handshake age.
reset_messages
NODE_ID=1
IS_LEADER=1
NODE_VPN_IP=([1]=10.5.4.1 [2]=10.5.4.2 [3]=10.5.4.3 [4]=10.5.4.4 [5]=10.5.4.5)
VPN_IP_NODE=([10.5.4.1]=1 [10.5.4.2]=2 [10.5.4.3]=3 [10.5.4.4]=4 [10.5.4.5]=5)
wg_dump=$'PRIVATE_CANARY\tpub\t55820\toff\n'
wg_dump+=$'peer2\t(none)\t192.0.2.2:55820\t10.5.4.2/32\t9940\t1\t1\t25\n'
wg_dump+=$'peer3\t(none)\t(none)\t10.5.4.3/32\t0\t0\t0\t25\n'
wg_dump+=$'peer4\t(none)\t192.0.2.4:55820\t10.5.4.4/32\t1000\t1\t1\t25\n'
evaluate_wireguard_peers "$wg_dump" 10000 >> "$fixture_root/output"
assert_eq "$PROBLEMS" 2 'never and stale handshakes are problems'
assert_contains "${PROBLEM_MSGS[0]}" 'node 3 (10.5.4.3) never completed' 'peer named after its node'
assert_contains "${PROBLEM_MSGS[1]}" 'node 4 (10.5.4.4) last WireGuard handshake 2h 30m ago' 'handshake age reported'
assert_eq "$WARNINGS" 1 'registered node without a peer warns on the leader'
assert_contains "${WARNING_MSGS[0]}" 'node 5 is registered' 'missing peer named'

# Kamailio dispatcher destination flags.
reset_messages
dispatcher=$'\t\t\t\tDEST: {\n\t\t\t\t\tURI: sip:10.5.4.1:24005\n\t\t\t\t\tFLAGS: AX\n'
dispatcher+=$'\t\t\t\tDEST: {\n\t\t\t\t\tURI: sip:10.5.4.2:24005\n\t\t\t\t\tFLAGS: IP\n'
evaluate_dispatcher_destinations proxy "$dispatcher" >> "$fixture_root/output"
assert_eq "$PROBLEMS" 1 'inactive dispatcher destination is a problem'
assert_contains "${PROBLEM_MSGS[0]}" 'sip:10.5.4.2:24005 is inactive' 'inactive destination named'
evaluate_dispatcher_destinations proxy '' >> "$fixture_root/output"
assert_eq "$WARNINGS" 1 'empty dispatcher warns'

# Backup coverage, failures, stale references and opt-out flags.
reset_messages
redis="$fixture_root/redis"
mkdir -p "$redis"
printf 'cluster/backup/1\ncluster/backup/2\ncluster/backup/3\ncluster/backup/4\n' > "$redis/cluster_backup_*.scan"
backup_fixture() {
    printf '%s' "$2" > "$redis/cluster_backup_$1.name"
    printf '%s' "$3" > "$redis/cluster_backup_$1.enabled"
    printf '%s' "$4" > "$redis/cluster_backup_$1.instances"
    printf '{"interval": "daily"}' > "$redis/cluster_backup_$1.schedule_hint"
}
backup_fixture 1 Daily 1 'mod1 removed9'
backup_fixture 2 Second 1 mod2
backup_fixture 3 Paused '' mod3
backup_fixture 4 Empty 1 removed8
now=$(date +%s)
printf '{"start": %s, "end": %s, "errors": 0}' $((now - 3700)) $((now - 3600)) > "$redis/node_1_backup_status_1.mod1"
printf '{"start": %s, "end": %s, "errors": 2}' $((now - 3700)) $((now - 3600)) > "$redis/node_1_backup_status_2.mod2"
touch "$redis/module_mod4_flags.no_data_backup"
CLUSTER_MODULE_NODE=([mod1]=1 [mod2]=1 [mod3]=1 [mod4]=1 [nethvoice5]=2)
MODULES=$'mod1\nmod2\nmod3\nmod4'
check_backups >> "$fixture_root/output"
assert_eq "$PROBLEMS" 1 'failed backup run is a problem'
assert_contains "${PROBLEM_MSGS[0]}" "mod2: backup 'Second' (id 2): last run failed with 2 error(s)" 'failed backup named'
assert_eq "$WARNINGS" 4 'stale references, empty enabled backup and uncovered module warn'
assert_contains "${WARNING_MSGS[*]}" "mod3: not included in any enabled backup (only in disabled 'Paused')" 'disabled-only coverage warns'
assert_contains "${WARNING_MSGS[*]}" "Backup 'Empty' (id 4) is enabled but includes no installed module" 'empty enabled backup warns'
[[ "${WARNING_MSGS[*]}" != *mod4* ]] || fail 'no_data_backup module warned'
printf '{"start": 1, "end": 2, "errors": 0}' > "$redis/node_1_backup_status_1.mod1"
reset_messages
check_backups >> "$fixture_root/output"
assert_contains "${WARNING_MSGS[*]}" "mod1: backup 'Daily' (id 1): last run completed" 'overdue backup warns'

# Leftover homes are module-like names with NS8 state and no cluster module.
reset_messages
mkdir -p "$fixture_root/homes/orphan12/.config/state" "$fixture_root/homes/nethvoice5/.config/state" \
    "$fixture_root/homes/admin/.config/state" "$fixture_root/homes/plain3"
check_orphan_module_homes "$fixture_root/homes" >> "$fixture_root/output"
assert_eq "$WARNINGS" 1 'only the removed module home warns'
assert_contains "${WARNING_MSGS[0]}" "$fixture_root/homes/orphan12" 'leftover home path reported'

# Background queries keep exact output bytes and the command status.
mkdir "$fixture_root/bg"
BG_DIR="$fixture_root/bg"
start_query sample printf 'value\n\n'
start_query failing sh -c 'printf partial; exit 3'
fetch_query sample || fail 'started query is not available'
assert_eq "$QUERY_OUTPUT" $'value\n\n' 'trailing newlines preserved'
assert_eq "$QUERY_RC" 0 'successful query status'
fetch_query failing || fail 'failed query is not available'
assert_eq "$QUERY_OUTPUT|$QUERY_RC" 'partial|3' 'failed query output and status'
if fetch_query never-started; then fail 'unknown query reported as available'; fi
BG_DIR=""

# Helpers for sizes and JSON output.
assert_eq "$(size_to_bytes '15.71GB (89%)')" 15710000000 'Podman sizes are parsed'
assert_eq "$(json_string $'a"b\\c\nd\001')" '"a\"b\\c\nd"' 'JSON strings are escaped'
reset_messages
problem 'one "quoted"' > /dev/null
warning 'two' > /dev/null
json=$(print_json_report)
assert_contains "$json" '"problems":["one \"quoted\""],"warnings":["two"]' 'JSON report lists messages'
if command -v jq >/dev/null 2>&1; then
    jq -e '.problem_count == 1 and .warning_count == 1' <<< "$json" >/dev/null || fail 'JSON report is not valid JSON'
fi

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

# pasta.* accepts the bare process name and suffixes, but requires its prefix.
cat > "$fixture_root/bin/ss" <<'MOCK'
#!/bin/bash
process=$(cat "$DIAGNOSTIC_FIXTURES/listener-process")
printf 'LISTEN 0 128 0.0.0.0:20107 0.0.0.0:* users:(("%s",pid=1,fd=1))\n' "$process"
MOCK
for var_name in REPORTS_REDIS_PORT POSTGRES_PORT REDIS_PORT; do
    for process in pasta pasta.avx2 pasta-helper node notpasta; do
        printf '%s\n' "$process" > "$fixture_root/listener-process"
        reset_messages
        if check_configured_service_port voice "$var_name" 20107 \
            "$(get_whitelist_port_expected_regex "$var_name")" \
            "$(get_whitelist_port_expected_service "$var_name")" >> "$fixture_root/output"; then
            result=0
        else
            result=1
        fi
        case "$process" in
            pasta*) expected=0 ;;
            *) expected=1 ;;
        esac
        assert_eq "$result" "$expected" "$var_name owner check for $process"
        assert_eq "$PROBLEMS" "$expected" "$var_name findings for $process"
    done
done

if grep -Eq 'SECRET_CANARY|IDENTIFIER_CANARY|SIP_IDENTITY_CANARY|CUSTOMER_CANARY|PRIVATE_CANARY' "$fixture_root/output" "$fixture_root/memory-output"; then
    fail 'raw command metadata or contact identities disclosed'
fi
printf 'PASS: service contexts, restart recency, container health, memory, Asterisk aggregates, cluster VPN, backups, leftovers, proxy, JSON\n'
