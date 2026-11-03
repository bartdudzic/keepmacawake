#!/bin/bash
# Tests the workflow's scripts with a fake keepmacawake command, checks that
# every Script Filter answer is valid JSON, then builds the workflow twice and
# compares the files. The scripts run in a clean environment that points them
# at the fake command, so the tests never reach the real one.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

# The fake command logs its arguments and answers like the real one; the
# answers come from FAKE_STATUS, FAKE_START, FAKE_STOP ("none" prints nothing)
# and FAKE_CODE.
cat > "$work/keepmacawake" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_LOG"
answer() { [ "$1" = none ] || printf '%b\n' "$1"; }
case "$1" in
    status) answer "${FAKE_STATUS:-Off: this Mac sleeps as usual.}" ;;
    start) answer "${FAKE_START:-Awake: keeping this Mac awake, 8 h left.\nPower: AC power only.}" ;;
    stop) answer "${FAKE_STOP:-Off: this Mac sleeps as usual.}" ;;
esac
exit "${FAKE_CODE:-0}"
FAKE
chmod +x "$work/keepmacawake"
FAKE_LOG="$work/log"
: > "$FAKE_LOG"

# Runs a script in a clean environment whose KEEPMACAWAKE_CLI is the fake
# command, or a missing file with CLI=missing. The scripts try no other path
# while KEEPMACAWAKE_CLI is set. Per-test answers are passed as FAKE_* variables.
sandbox() {
    local cli="$work/keepmacawake" vars=() name
    [ "${CLI:-}" = missing ] && cli="$work/missing"
    for name in FAKE_STATUS FAKE_START FAKE_STOP FAKE_CODE; do
        if [ -n "${!name+set}" ]; then vars+=("$name=${!name}"); fi
    done
    env -i HOME="$work" PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=en_US.UTF-8 \
        KEEPMACAWAKE_CLI="$cli" FAKE_LOG="$FAKE_LOG" ${vars[@]+"${vars[@]}"} "$@"
}
run() { sandbox "$here/src/run.sh" "$@"; }
# Runs filter.sh with a query, checks that the answer is JSON and prints it.
filter() {
    sandbox "$here/src/filter.sh" "$@" > "$work/out.json"
    /usr/bin/plutil -convert xml1 -o "$work/out.plist" "$work/out.json" 2>/dev/null ||
        fail "not JSON for '$*': $(cat "$work/out.json")"
    cat "$work/out.json"
}
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
expect() { case "$2" in *"$3"*) ;; *) fail "$1: expected '$3' in: $2" ;; esac; }
refuse() { case "$2" in *"$3"*) fail "$1: did not expect '$3' in: $2" ;; esac; }

# filter.sh
out=$(filter '')
expect 'empty query, status' "$out" '"title":"Off: this Mac sleeps as usual."'
expect 'empty query, 1 h' "$out" '"arg":"start --hours 1"'
expect 'empty query, 8 h' "$out" '"arg":"start --hours 8"'
expect 'empty query, no limit' "$out" '"arg":"start --unlimited"'
expect 'empty query, stop' "$out" '"arg":"stop"'
expect 'empty query, custom' "$out" 'Type the hours after the keyword'
[ "$(cat "$FAKE_LOG")" = 'status --no-input --timeout 5' ] || fail "filter ran: $(cat "$FAKE_LOG")"

out=$(filter '3')
expect 'number' "$out" '"arg":"start --hours 3"'
expect 'number, title' "$out" 'for 3 hours'
out=$(filter '1h')
expect 'one hour' "$out" '"title":"Keep this Mac awake for 1 hour"'
out=$(filter 'start 24 hours')
expect 'start N hours' "$out" '"arg":"start --hours 24"'
for big in 169 0 99999999999999999999; do
    out=$(filter "$big")
    expect "out of range $big" "$out" 'Pick 1 to 168 hours'
    refuse "out of range $big" "$out" 'start --hours'
done

out=$(filter 'stop')
expect 'stop' "$out" '"arg":"stop"'
refuse 'stop only' "$out" 'start --hours'
out=$(filter 'Unl')
expect 'unlimited' "$out" '"arg":"start --unlimited"'
refuse 'unlimited only' "$out" '"arg":"stop"'
out=$(filter 'status')
expect 'status' "$out" '"arg":"status"'
out=$(filter 'zzz')
expect 'no match' "$out" 'No matching action'

out=$(FAKE_STATUS='Awake: keeping this Mac awake, 7 h 59 min left.\nPower: AC power only.\nTrial: 2 days left.' filter '')
expect 'running session' "$out" '"title":"Awake: keeping this Mac awake, 7 h 59 min left."'
expect 'running session, subtitle' "$out" '"subtitle":"Power: AC power only. Trial: 2 days left."'
out=$(FAKE_STATUS='Needs attention: a "quoted" \\ value\tand a tab' filter '')
expect 'escaping' "$out" 'a \"quoted\" \\ value and a tab'
out=$(FAKE_STATUS='Error: the background service is not available.' FAKE_CODE=6 filter '')
expect 'service down' "$out" 'Keep Mac Awake is not running'
refuse 'service down' "$out" 'start --hours'
out=$(CLI=missing filter '')
expect 'not installed' "$out" '"arg":"website"'
expect 'not installed, copy' "$out" 'free trial'

# run.sh
: > "$FAKE_LOG"
out=$(run 'start --hours 8')
expect 'run start' "$out" 'Awake: keeping this Mac awake, 8 h left.'
run 'start --unlimited' > /dev/null
run 'stop' > /dev/null
run 'status' > /dev/null
[ "$(cat "$FAKE_LOG")" = "$(printf 'start --hours 8 --no-input\nstart --unlimited --no-input\nstop --no-input\nstatus --no-input')" ] ||
    fail "run.sh ran: $(cat "$FAKE_LOG")"
: > "$FAKE_LOG"
for bad in 'start --hours 0' 'start --hours 169' 'start --hours 8; rm -rf ~' 'start --hours 1 --json' 'config set --battery allowed' 'buy' ''; do
    out=$(run "$bad")
    [ -n "$out" ] || fail "run.sh '$bad' printed nothing"
done
[ ! -s "$FAKE_LOG" ] || fail "run.sh ran the command for a refused action: $(cat "$FAKE_LOG")"
out=$(FAKE_STOP=none FAKE_CODE=5 run 'stop')
expect 'empty answer' "$out" 'exit code 5'
out=$(FAKE_START='Error: AC power is needed.' FAKE_CODE=4 run 'start --hours 2')
expect 'refusal shown' "$out" 'Error: AC power is needed.'
out=$(CLI=missing run 'start --hours 8')
expect 'run, not installed' "$out" 'Keep Mac Awake is not installed'

# The build: a valid plist, the scripts inside, the same bytes twice.
"$here/build.sh" "$work/one" > /dev/null
sleep 1
"$here/build.sh" "$work/two" > /dev/null
cmp -s "$work/one/Keep-Mac-Awake.alfredworkflow" "$work/two/Keep-Mac-Awake.alfredworkflow" || fail 'two builds differ'
mkdir "$work/unzipped"
(cd "$work/unzipped" && /usr/bin/unzip -q "$work/one/Keep-Mac-Awake.alfredworkflow")
/usr/bin/plutil -lint -s "$work/unzipped/info.plist" || fail 'info.plist is not valid'
[ "$(/usr/bin/plutil -extract bundleid raw -o - "$work/unzipped/info.plist")" = com.keepmacawake.alfred ] || fail 'bundle id'
readme=$(/usr/bin/plutil -extract readme raw -o - "$work/unzipped/info.plist")
expect 'readme' "$readme" '## Usage'
refuse 'readme' "$readme" '## Build'
{ [ -x "$work/unzipped/filter.sh" ] && [ -x "$work/unzipped/run.sh" ]; } || fail 'scripts are not executable in the bundle'
[ "$(sips -g pixelWidth "$work/unzipped/icon.png" | awk '/pixelWidth/ {print $2}')" -ge 256 ] || fail 'icon smaller than 256 px'

if [ "$failures" -gt 0 ]; then
    echo "$failures test(s) failed." >&2
    exit 1
fi
echo 'All Alfred workflow tests passed.'
