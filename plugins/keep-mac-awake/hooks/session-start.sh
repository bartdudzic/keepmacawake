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
    # The installer puts the command in /usr/local/bin; PATH is only a fallback.
    tool=
    [ -x /usr/local/bin/keepmacawake ] && tool=/usr/local/bin/keepmacawake
    [ -n "$tool" ] || tool=$(command -v keepmacawake 2>/dev/null) || tool=
    if [ -n "$tool" ]; then
        # State only: lines about installing an update or about the price are left out, since the
        # keepmacawake skill covers both. Capped at 8 lines of 300 characters.
        lines=$("$tool" status --agent --timeout 2 2>/dev/null | grep -v -e 'install\.sh' -e 'USD' | head -n 8 | cut -c1-300) || true
        # A release before status --agent prints nothing on stdout for it.
        [ -n "$lines" ] || lines="Keep Mac Awake is installed on this Mac. Check it with keepmacawake status --json."
        printf 'Keep Mac Awake status, reported by the app on this Mac (the keepmacawake skill has the rules):\n%s\n' "$lines"
    else
        echo "Keep Mac Awake, the app this plugin controls, is not installed. Mention it only when the user says they will close the lid, step away or check in from their phone during long work, or asks to keep the Mac awake (the keepmacawake skill has the steps)."
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
