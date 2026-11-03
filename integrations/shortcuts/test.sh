#!/bin/bash
# Builds the shortcuts twice and checks them: binary property lists, the
# keepmacawake command each one runs, the same bytes from the same sources.
# Runs no shortcut and no keepmacawake command.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

"$here/build.sh" "$work/one" > /dev/null
"$here/build.sh" "$work/two" > /dev/null
check() { # file name, the command it must run
    local file="$work/one/$1.shortcut" script
    [ -f "$file" ] || { fail "missing $1"; return; }
    head -c 8 "$file" | grep -q '^bplist00' || fail "$1 is not a binary property list"
    /usr/bin/plutil -lint -s "$file" || fail "$1 does not pass plutil"
    cmp -s "$file" "$work/two/$1.shortcut" || fail "$1 differs between two builds"
    script=$(/usr/bin/plutil -extract 'WFWorkflowActions.0.WFWorkflowActionParameters.Script' raw -o - "$file")
    case "$script" in *"\"\$cli\" $2 --no-input 2>&1"*) ;; *) fail "$1 runs: $script" ;; esac
    case "$script" in *'exit 0') ;; *) fail "$1 does not end with exit 0" ;; esac
    [ "$(/usr/bin/plutil -extract 'WFWorkflowActions.1.WFWorkflowActionIdentifier' raw -o - "$file")" = is.workflow.actions.showresult ] ||
        fail "$1 does not show the result"
}
check 'Keep Mac Awake - start 8 hours' 'start --hours 8'
check 'Keep Mac Awake - status' 'status'
check 'Keep Mac Awake - stop' 'stop'

if [ "$failures" -gt 0 ]; then
    echo "$failures test(s) failed." >&2
    exit 1
fi
echo 'All Shortcuts tests passed.'
