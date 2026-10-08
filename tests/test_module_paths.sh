#!/bin/bash
# The sourced analyzer returns before main; ShellCheck follows its direct-run exits.
# shellcheck disable=SC2317,SC2329
# Local regression tests: source helpers only; never run the full analyzer.
set -uo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixture_root=$(mktemp -d)
trap 'chmod -R u+rwX "$fixture_root"; rm -rf -- "$fixture_root"' EXIT
export FIXTURE_ROOT="$fixture_root"
mkdir -p "$fixture_root/bin" "$fixture_root/runtime" "$fixture_root/passwd"
export PATH="$fixture_root/bin:$PATH"

cat > "$fixture_root/bin/runagent" <<'MOCK'
#!/bin/bash
# The FreePBX snapshot script runs locally against the asterisk mock.
if [[ $1 == -m && $3 == podman && $4 == exec && $5 == freepbx && $6 == sh ]]; then
    shift 5
    exec "$@" </dev/null
fi
# Module context: execution UID, then printenv AGENT_STATE_DIR output.
[[ $# == 5 && $1 == -m && $3 == sh && $4 == -c && $5 == *'printenv AGENT_STATE_DIR'* ]] || exit 99
# Lookups must not consume a module discovery loop's input.
if IFS= read -r unexpected; then exit 98; fi
printf '%s\n' "$2" >> "$FIXTURE_ROOT/runagent.calls"
[[ -f "$FIXTURE_ROOT/runtime/$2.sleep" ]] && sleep 10
printf '1001\n'
cat -- "$FIXTURE_ROOT/runtime/$2.out" 2>/dev/null
[[ "$(cat "$FIXTURE_ROOT/runtime/$2.rc" 2>/dev/null)" == 0 ]] || exit 3
MOCK
cat > "$fixture_root/bin/asterisk" <<'MOCK'
#!/bin/bash
[[ $# == 2 && $1 == -rx && $2 == 'pjsip show transports' ]] || exit 1
printf 'Transport: fixture 0.0.0.0:15062\n'
MOCK
cat > "$fixture_root/bin/getent" <<'MOCK'
#!/bin/bash
[[ $# == 2 && $1 == passwd ]] || exit 99
if IFS= read -r unexpected; then exit 98; fi
printf '%s\n' "$2" >> "$FIXTURE_ROOT/getent.calls"
[[ -f "$FIXTURE_ROOT/passwd/$2" ]] || exit 2
cat -- "$FIXTURE_ROOT/passwd/$2"
MOCK
cat > "$fixture_root/bin/findmnt" <<'MOCK'
#!/bin/bash
[[ $# == 5 && $1 == -n && $2 == -o && $3 == TARGET && $4 == --target ]] || exit 99
case "$5" in
    /|"$FIXTURE_ROOT"/on-root/*) printf '/\n' ;;
    "$FIXTURE_ROOT"/home/*) printf '%s/home\n' "$FIXTURE_ROOT" ;;
    "$FIXTURE_ROOT"/home2/*) printf '%s/home2\n' "$FIXTURE_ROOT" ;;
    *) exit 1 ;;
esac
MOCK
cat > "$fixture_root/bin/df" <<'MOCK'
#!/bin/bash
[[ $# == 3 && ($1 == -h || $1 == -P) && $2 == -- ]] || exit 99
printf '%s|%s\n' "$1" "$3" >> "$FIXTURE_ROOT/df.calls"
case "$3" in
    "$FIXTURE_ROOT"/home/*) pct=85 ;;
    "$FIXTURE_ROOT"/home2/*) pct=95 ;;
    *) exit 1 ;;
esac
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'mock 100 90 10 %s%% /fixture\n' "$pct"
MOCK
cat > "$fixture_root/bin/ss" <<'MOCK'
#!/bin/bash
cat "$FIXTURE_ROOT/ss.out"
MOCK
printf 'tcp LISTEN 0 128 0.0.0.0:15062 0.0.0.0:* users:(("asterisk",pid=1,fd=1))\n' > "$fixture_root/ss.out"
printf 'tcp LISTEN 0 128 0.0.0.0:15063 0.0.0.0:* users:(("asterisk",pid=1,fd=2))\n' >> "$fixture_root/ss.out"
chmod +x "$fixture_root/bin/"*

# shellcheck source=sysanal3
source "$repo_dir/sysanal3"
RUNAGENT_TIMEOUT=2

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3 (expected '$2', got '$1')"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3"; }

runtime() {
    printf '%s' "$2" > "$fixture_root/runtime/$1.out"
    printf '%s\n' "${3:-0}" > "$fixture_root/runtime/$1.rc"
}
account() {
    printf '%s:x:1001:1001:Module:%s:/sbin/nologin\n' "$1" "$2" > "$fixture_root/passwd/$1"
}
environment() {
    mkdir -p -- "$1"
    cat > "$1/environment" <<'ENV'
TRAEFIK_HOST=fixture.example.test
NETHVOICE_HOST=voice.example.test
KML_DEFAULT_FQDN=proxy.example.test
ASTERISK_SIPS_PORT=15063
ASTERISK_SIP_PORT=15062
PROXY_PORT=15060
SECRET_CANARY=DO_NOT_DISCLOSE_7f893
UNUSED=$(touch "$FIXTURE_ROOT/executed-dollar")
UNUSED_BACKTICK=`touch "$FIXTURE_ROOT/executed-backtick"`
UNUSED_SEMICOLON=anything; touch "$FIXTURE_ROOT/executed-semicolon"
ENV
}
resolve_ok() {
    resolve_module_paths "$1" >> "$fixture_root/output" || fail "resolution of $1"
    assert_eq "${MODULE_ENV_FILES[$1]}" "$2" "environment path for $1"
}
resolve_fail() {
    local before=$WARNINGS
    if resolve_module_paths "$1" >> "$fixture_root/output"; then fail "unexpected success for $1"; fi
    assert_eq "$WARNINGS" "$((before + 1))" "one warning for $1"
    if resolve_module_paths "$1" >> "$fixture_root/output"; then fail "cached failure for $1"; fi
    assert_eq "$WARNINGS" "$((before + 1))" "cached warning count for $1"
    assert_eq "$(grep -cx "$1" "$fixture_root/runagent.calls")" 1 "one runtime call for $1"
    assert_eq "$(grep -cx "$1" "$fixture_root/getent.calls")" 1 "one NSS call for $1"
}

# Exercise the same entry-point identity as bash <(curl ...), without main code.
sed '/^main "\$@"$/,$d' "$repo_dir/sysanal3" > "$fixture_root/launch-prefix"
printf "printf 'process-substitution launch reaches main\\n'\n" >> "$fixture_root/launch-prefix"
assert_eq "$(bash <(cat "$fixture_root/launch-prefix"))" 'process-substitution launch reaches main' 'normal launch source guard'

analyzer_home=$HOME
for mod in conventional relocated 'spaces'; do
    case "$mod" in
        conventional) module_home="$fixture_root/home/$mod" ;;
        relocated) module_home="$fixture_root/home2/$mod" ;;
        spaces) module_home="$fixture_root/home2/module with spaces" ;;
    esac
    account "$mod" "$module_home"
    runtime "$mod" '' 1
    environment "$module_home/.config/state"
    resolve_ok "$mod" "$module_home/.config/state/environment"
    resolve_ok "$mod" "$module_home/.config/state/environment"
    assert_eq "${MODULE_HOMES[$mod]}" "$module_home" "NSS field 6 for $mod"
    assert_eq "$(grep -cx "$mod" "$fixture_root/runagent.calls")" 1 "cached success for $mod"
done
assert_eq "$HOME" "$analyzer_home" 'analyzer HOME unchanged'

# Authoritative custom state and rootful state do not depend on NSS layout.
account override "$fixture_root/home/override"
environment "$fixture_root/home/override/.config/state"
environment "$fixture_root/custom state/override"
runtime override "$fixture_root/custom state/override"$'\n'
resolve_ok override "$fixture_root/custom state/override/environment"
environment "$fixture_root/rootful/state"
runtime rootful "$fixture_root/rootful/state"$'\n'
resolve_ok rootful "$fixture_root/rootful/state/environment"
assert_eq "${MODULE_HOMES[rootful]:-}" '' 'rootful module needs no account'

# Invalid outputs, including an extra trailing blank line, must use NSS.
for mod in failed empty relative multiline blankline control timeout; do
    account "$mod" "$fixture_root/home/$mod"
    environment "$fixture_root/home/$mod/.config/state"
    case "$mod" in
        failed) runtime "$mod" "$fixture_root/stale" 1 ;;
        empty) runtime "$mod" '' ;;
        relative) runtime "$mod" 'relative/state' ;;
        multiline) runtime "$mod" "$fixture_root/first"$'\n'"$fixture_root/second"$'\n' ;;
        blankline) runtime "$mod" "$fixture_root/first"$'\n\n' ;;
        control) runtime "$mod" "$fixture_root/state"$'\r\n' ;;
        timeout) runtime "$mod" ''; touch "$fixture_root/runtime/$mod.sleep" ;;
    esac
    resolve_ok "$mod" "$fixture_root/home/$mod/.config/state/environment"
done
assert_eq "$WARNINGS" 0 'successful fallbacks do not warn'

# Do not accept an unrelated NSS account, malformed rows, or relative homes.
for mod in missing-account wrong-account relative-home multiline-account malformed-account; do
    runtime "$mod" '' 1
    case "$mod" in
        wrong-account) account "$mod" "$fixture_root/home/$mod"; sed -i 's/^wrong-account:/other:/' "$fixture_root/passwd/$mod" ;;
        relative-home) account "$mod" 'relative/home' ;;
        multiline-account) account "$mod" "$fixture_root/home/$mod"; printf '\n' >> "$fixture_root/passwd/$mod" ;;
        malformed-account) printf '%s:x:1:1:home\n' "$mod" > "$fixture_root/passwd/$mod" ;;
    esac
    resolve_fail "$mod"
    assert_contains "${WARNING_MSGS[-1]}" 'no valid NSS account home' "actionable NSS warning for $mod"
done

account missing-file "$fixture_root/home2/missing-file"
runtime missing-file '' 1
resolve_fail missing-file
assert_contains "${WARNING_MSGS[-1]}" "$fixture_root/home2/missing-file/.config/state/environment" 'failed NSS path included'
assert_contains "${WARNING_MSGS[-1]}" 'file is missing' 'missing file reason included'

# A missing authoritative file must not be replaced by a stale NSS file.
account stale-fallback "$fixture_root/home/stale-fallback"
environment "$fixture_root/home/stale-fallback/.config/state"
runtime stale-fallback "$fixture_root/custom/missing"$'\n'
resolve_fail stale-fallback
assert_eq "${MODULE_ENV_FILES[stale-fallback]}" "$fixture_root/custom/missing/environment" 'authoritative failure path retained'
assert_contains "${WARNING_MSGS[-1]}" "$fixture_root/custom/missing/environment" 'authoritative warning path included'

runtime directory "$fixture_root/not-regular"$'\n'
mkdir -p "$fixture_root/not-regular/environment"
resolve_fail directory
assert_contains "${WARNING_MSGS[-1]}" 'not a regular file' 'non-regular file reason included'

runtime unreadable "$fixture_root/unreadable"$'\n'
environment "$fixture_root/unreadable"
chmod 000 "$fixture_root/unreadable/environment"
if [[ $EUID -eq 0 ]]; then
    # Root bypasses mode bits: exercise the actual -r check without privileges.
    cp "$repo_dir/sysanal3" "$fixture_root/analyzer"
    # A restrictive caller umask must not prevent the unprivileged reader from
    # reaching the analyzer. Use in-process lookup mocks in this permission test.
    chmod o+x "$fixture_root" "$fixture_root/unreadable"
    chmod o+r "$fixture_root/analyzer"
    # The inner shell owns positional arguments and diagnostic counters.
    # shellcheck disable=SC2016
    setpriv --reuid=65534 --regid=65534 --clear-groups bash -c '
        source "$1/analyzer"
        timeout() { shift; "$@"; }
        runagent() { printf "1001\n%s/unreadable\n" "$FIXTURE_ROOT"; }
        getent() { return 2; }
        resolve_module_paths unreadable >/dev/null && exit 1
        resolve_module_paths unreadable >/dev/null && exit 1
        [[ $WARNINGS == 1 && ${MODULE_PATH_STATUS[unreadable]} == 1 &&
            ${WARNING_MSGS[0]} == *"environment file is unreadable"* ]] || {
            printf "Unreadable-file assertion failed: warnings=%s reason=%s\n" \
                "$WARNINGS" "${WARNING_MSGS[0]:-no warning}" >&2
            exit 1
        }
    ' bash "$fixture_root" || fail 'unreadable file rejection without root privileges'
else
    resolve_fail unreadable
    assert_contains "${WARNING_MSGS[-1]}" 'file is unreadable' 'unreadable file reason included'
fi
chmod 600 "$fixture_root/unreadable/environment"

# Exercise real consumers and targeted readers against cached paths.
check_configured_service_port() {
    printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$fixture_root/ports"
    return 0
}
check_tls_certificate_endpoint() {
    printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$fixture_root/certificates"
}
check_port_owner() {
    printf '%s|%s\n' "$1" "$2" >> "$fixture_root/listeners"
}
LOCAL_VPN_ADDRESS=10.5.4.3
NETHVOICE_PROXY_ROUTE_COUNT=1
NETHVOICE_PROXY_DOMAIN_URI_MAP[voice.example.test]='sip:10.5.4.3:15062'
NETHVOICE_PROXY_DOMAIN_SOURCE_MAP[voice.example.test]=fixture-proxy
for mod in conventional relocated spaces override rootful; do
    {
        report_module_traefik_host "$mod"
        check_nethvoice_proxy_certificates "$mod"
        check_nethvoice_certificate "$mod"
        check_nethvoice_proxy_domain_uri "$mod"
        check_nethvoice_asterisk_port_alignment "$mod"
        check_nethvoice_listening_ports "$mod"
    } >> "$fixture_root/output"
    assert_contains "$(cat "$fixture_root/certificates")" "$mod KML_DEFAULT_FQDN SIP/TLS|proxy.example.test|5061" 'proxy certificate uses resolved file'
    assert_contains "$(cat "$fixture_root/certificates")" "$mod NETHVOICE_HOST HTTPS|voice.example.test|443" 'instance certificate uses resolved file'
    assert_contains "$(cat "$fixture_root/listeners")" "$mod Asterisk SIP|15062" 'listening ports use resolved file'
    assert_contains "$(cat "$fixture_root/output")" "$mod: nethvoice-proxy route for voice.example.test matches" 'proxy route uses resolved file'
    audit_whitelist_ports_for_module "$mod" >> "$fixture_root/output"
    assert_contains "$(cat "$fixture_root/ports")" "$mod|ASTERISK_SIP_PORT|15062" 'ports read from resolved file'
    assert_eq "$(get_env_var "${MODULE_ENV_FILES[$mod]}" TRAEFIK_HOST)" fixture.example.test 'targeted host reader'
    assert_eq "$(grep -cx "$mod" "$fixture_root/runagent.calls")" 1 'consumer reuses cache'
done
before=$WARNINGS
for mod in missing-account stale-fallback directory; do
    audit_whitelist_ports_for_module "$mod"
    check_nethvoice_proxy_domain_uri "$mod"
    report_module_traefik_host "$mod"
    check_nethvoice_proxy_certificates "$mod"
    check_nethvoice_certificate "$mod"
    check_nethvoice_asterisk_port_alignment "$mod"
    check_nethvoice_listening_ports "$mod"
done >> "$fixture_root/output"
assert_eq "$PROBLEMS" 0 'valid listener alignment has no false problems'
assert_eq "$WARNINGS" "$before" 'failed consumers do not repeat warnings'
assert_eq "${#WARNING_MSGS[@]}" "$WARNINGS" 'warning messages match counter'

# A repaired fixture is still a cached failure during this run.
environment "$fixture_root/custom/missing"
if resolve_module_paths stale-fallback >> "$fixture_root/output"; then fail 'failed resolution was retried'; fi
assert_eq "$WARNINGS" "$before" 'failure stays cached after file appears'

# Forbidden listeners are independent of environment-file availability.
printf 'tcp LISTEN 0 128 0.0.0.0:5060 0.0.0.0:* users:(("asterisk",pid=1,fd=1))\n' > "$fixture_root/ss.out"
check_nethvoice_asterisk_port_alignment missing-account >> "$fixture_root/output"
assert_eq "$PROBLEMS" 1 'independent listener check continues on failed resolution'
PROBLEMS=0
PROBLEM_MSGS=()

# Resolution failures cannot suppress valid-module checks or real config warnings.
MODULES=$'missing-account\nrelocated\nrootful'
resolve_local_module_paths >> "$fixture_root/output"
assert_eq "$WARNINGS" "$before" 'discovery reuses both cache states'
environment "$fixture_root/no-values"
printf 'SECRET_CANARY=DO_NOT_DISCLOSE_7f893\n' > "$fixture_root/no-values/environment"
runtime no-values "$fixture_root/no-values"$'\n'
resolve_ok no-values "$fixture_root/no-values/environment"
check_nethvoice_proxy_domain_uri no-values >> "$fixture_root/output"
assert_eq "$WARNINGS" "$((before + 1))" 'missing configuration still warns'
assert_contains "${WARNING_MSGS[-1]}" 'NETHVOICE_HOST is not set' 'genuine config warning preserved'

# Shared mounts are checked once; / is already reported in general system data.
account on-root "$fixture_root/on-root/module"
environment "$fixture_root/on-root/module/.config/state"
runtime on-root '' 1
resolve_ok on-root "$fixture_root/on-root/module/.config/state/environment"
MODULES=$'conventional\noverride\nrelocated\nspaces\nmissing-file\non-root\nrootful'
SILENT=1
before=$WARNINGS
report_module_home_filesystems > "$fixture_root/filesystems"
assert_eq "$(wc -l < "$fixture_root/df.calls")" 4 'two df commands per unique non-root mount'
assert_eq "$(grep -c '\[INFO\]' "$fixture_root/filesystems")" 2 'filesystem usage remains visible in silent mode'
assert_eq "$PROBLEMS" 1 '95 percent flags a problem'
assert_eq "$WARNINGS" "$((before + 1))" '85 percent warns'
assert_contains "$(cat "$fixture_root/filesystems")" "$fixture_root/home2 filesystem" 'relocated filesystem reported'
[[ $(cat "$fixture_root/filesystems") != *'Root filesystem'* ]] || fail 'root report duplicated'
assert_eq "${#PROBLEM_MSGS[@]}" "$PROBLEMS" 'filesystem problems counted in parent'

[[ ! -e "$fixture_root/executed-dollar" && ! -e "$fixture_root/executed-backtick" && ! -e "$fixture_root/executed-semicolon" ]] || fail 'environment executed shell expressions'
if grep -Eq 'DO_NOT_DISCLOSE_7f893|SECRET_CANARY|UNUSED=' "$fixture_root/output" "$fixture_root/filesystems"; then
    fail 'environment contents or secrets disclosed'
fi
printf 'PASS: module paths, cached diagnostics, safe readers, and filesystem reporting\n'
