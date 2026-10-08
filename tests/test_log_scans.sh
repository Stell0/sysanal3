#!/bin/bash
# The sourced analyzer returns before main; ShellCheck follows its direct-run exits.
# shellcheck disable=SC2317,SC2329
set -uo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixture_root=$(mktemp -d)
trap 'rm -rf -- "$fixture_root"' EXIT
# shellcheck source=sysanal3
source "$repo_dir/sysanal3"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3 (expected '$2', got '$1')"; }
LOG_SCAN_MAX_BYTES=128
LOG_SCAN_MAX_LINES=10
MESSAGES_LOG_ERROR_PATTERNS=$'FATAL:\nOut of memory'
ASTERISK_FULL_LOG_ERROR_PATTERNS=$'Cannot create socket\nToo many open files'
export LOG_FIXTURE="$fixture_root/asterisk-full"

# An old error outside the byte window must not be included.
{
    printf 'FATAL: OLD_SECRET_CANARY\n'
    printf '%0256d\n' 0
    printf 'Current healthy state\n'
} > "$fixture_root/messages"
check_system_messages_log "$fixture_root/messages" > "$fixture_root/output"
assert_eq "$PROBLEMS" 0 'old errors outside byte limit are excluded'

# The line limit also applies independently of the byte limit.
LOG_SCAN_MAX_BYTES=1024
LOG_SCAN_MAX_LINES=2
printf 'FATAL: OLD_SECRET_CANARY\nhealthy one\nhealthy two\n' > "$fixture_root/messages"
check_system_messages_log "$fixture_root/messages" >> "$fixture_root/output"
assert_eq "$PROBLEMS" 0 'old errors outside line limit are excluded'

# Case-insensitive matching, one finding per pattern, and no raw records.
LOG_SCAN_MAX_LINES=10
cat > "$fixture_root/messages" <<'DATA'
fAtAl: SECRET_CANARY $(touch SHOULD_NEVER_RUN)
FATAL: SECRET_CANARY
Out of memory: CUSTOMER_CANARY
DATA
check_system_messages_log "$fixture_root/messages" >> "$fixture_root/output"
assert_eq "$PROBLEMS" 2 'each matching pattern emits one finding'
assert_eq "${#PROBLEM_MSGS[@]}" 2 'parent counters are preserved'
check_system_messages_log "$fixture_root/missing" >> "$fixture_root/output"
assert_eq "$WARNINGS" 1 'missing logs warn instead of being considered healthy'
if scan_recent_log_patterns "$fixture_root/missing" FATAL: >> "$fixture_root/output" 2>/dev/null; then
    fail 'failed pipeline treated as a successful scan'
fi
LOG_SCAN_MAX_BYTES=invalid
check_system_messages_log "$fixture_root/messages" >> "$fixture_root/output"
assert_eq "$WARNINGS" 2 'invalid scan limits warn'
LOG_SCAN_MAX_BYTES=1024

# Exercise the real helper sent into the mocked FreePBX container.
mkdir "$fixture_root/bin"
cat > "$fixture_root/bin/runagent" <<'MOCK'
#!/bin/bash
[[ $1 == -m && $2 == voice && $3 == podman && $4 == exec && $5 == -i && $6 == freepbx ]] || exit 99
shift 6
args=("$@")
[[ ${args[0]} == bash && ${args[1]} == -s && ${args[2]} == -- ]] || exit 99
args[3]="$LOG_FIXTURE"
exec "${args[@]}"
MOCK
chmod +x "$fixture_root/bin/runagent"
export PATH="$fixture_root/bin:$PATH"
printf 'Cannot create socket: SIP_IDENTITY_CANARY\nToo many open files: SECRET_CANARY\n' > "$LOG_FIXTURE"
check_nethvoice_asterisk_full_logs voice >> "$fixture_root/output"
assert_eq "$PROBLEMS" 4 'container scan reports its matching patterns'
rm "$LOG_FIXTURE"
check_nethvoice_asterisk_full_logs voice >> "$fixture_root/output"
assert_eq "$WARNINGS" 3 'missing container log is an unknown result'

if grep -Eq 'SECRET_CANARY|CUSTOMER_CANARY|SIP_IDENTITY_CANARY|SHOULD_NEVER_RUN' "$fixture_root/output"; then
    fail 'raw log records disclosed'
fi
[[ ! -e SHOULD_NEVER_RUN ]] || fail 'log data executed as shell code'
printf 'PASS: bounded single-pass host/container log scans, errors, and private output\n'
