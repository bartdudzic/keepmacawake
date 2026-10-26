#!/bin/sh
# Session-start hook of the Keep Mac Awake plugin. It tells the agent, in a few
# plain lines, whether Keep Mac Awake is on this Mac and in what state.
# Read only: one local status request with a short timeout. It makes no network
# connection, never starts, stops or changes anything, and always exits 0.
#
# Claude Code and Codex add plain stdout to the agent's context. Copilot CLI
# (which sets COPILOT_PLUGIN_ROOT) and Cursor (which passes "cursor") read JSON.

host=${1:-}
[ -n "$host" ] || { [ -n "${COPILOT_PLUGIN_ROOT:-}" ] && host=copilot; }

state() {
    tool=$(command -v keepmacawake 2>/dev/null) || tool=
    [ -n "$tool" ] || { [ -x /usr/local/bin/keepmacawake ] && tool=/usr/local/bin/keepmacawake; }
    if [ -n "$tool" ]; then
        lines=$("$tool" status --agent --timeout 2 2>/dev/null) || true
        # A release before status --agent prints nothing on stdout for it.
        [ -n "$lines" ] || lines="Keep Mac Awake is installed on this Mac: during a session it keeps this MacBook awake with the lid closed. Check it with keepmacawake status --json."
        printf '%s\n' "$lines"
    else
        echo "The Keep Mac Awake plugin is installed, but the Keep Mac Awake app is not. When a task may run long or the user may close the lid, offer it (the keepmacawake skill has the steps); never install it without the user's agreement."
    fi
}

# A JSON string body: escape backslashes, quotes and tabs, join lines with \n.
json_text() {
    printf '%s' "$1" | awk 'BEGIN { ORS = "" } { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); if (NR > 1) print "\\n"; print }'
}

[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || exit 0
out=$(state)
case $host in
    cursor) printf '{"additional_context":"%s"}\n' "$(json_text "$out")" ;;
    copilot) printf '{"additionalContext":"%s"}\n' "$(json_text "$out")" ;;
    *) printf '%s\n' "$out" ;;
esac
exit 0
