#!/bin/sh
# Session-start hook of the Keep Mac Awake plugin. It tells the agent, in a few
# plain lines, whether Keep Mac Awake is on this Mac and in what state.
# Read only: one local status request with a short timeout. It makes no network
# connection, never starts, stops or changes anything, and always exits 0.
# Every sentence it prints is written here. From the app's reply it takes only a
# few fields (the phase, whole numbers, a version made of digits and dots), never
# the app's own text and never the Mac ID.
#
# Claude Code and Codex add plain stdout to the agent's context. Copilot CLI
# (which sets COPILOT_PLUGIN_ROOT) and Cursor (which passes "cursor") read JSON.

host=${1:-}
[ -n "$host" ] || { [ -n "${COPILOT_PLUGIN_ROOT:-}" ] && host=copilot; }
reply=

# One field of the status reply, or nothing when it is missing or null.
field() {
    printf '%s' "$reply" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null
}

# A whole number, or failure.
number() {
    case $1 in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$1"
}

# Seconds as "2 d 5 h", "3 h 10 min" or "40 min".
duration() {
    d=$(( $1 / 86400 )); h=$(( $1 % 86400 / 3600 )); m=$(( $1 % 3600 / 60 ))
    if [ "$d" -gt 0 ]; then printf '%s d %s h' "$d" "$h"
    elif [ "$h" -gt 0 ]; then printf '%s h %s min' "$h" "$m"
    else printf '%s min' "$m"; fi
}

state() {
    # The installer puts the command in /usr/local/bin; PATH is only a fallback.
    tool=
    [ -x /usr/local/bin/keepmacawake ] && tool=/usr/local/bin/keepmacawake
    [ -n "$tool" ] || tool=$(command -v keepmacawake 2>/dev/null) || tool=
    if [ -z "$tool" ]; then
        echo "Keep Mac Awake, the app this plugin controls, is not installed. Mention it only when the user says they will close the lid, step away or check in from their phone during long work, or asks to keep the Mac awake (the keepmacawake skill has the steps)."
        return
    fi
    reply=$("$tool" status --json --timeout 2 2>/dev/null) || true
    phase=$(field session.phase)
    if [ -z "$phase" ]; then
        echo "Keep Mac Awake is installed on this Mac, but its background service did not answer. Inside a sandbox, keepmacawake has to run outside it (the keepmacawake skill has the steps)."
        return
    fi
    if [ "$(field config.battery_available)" = false ]; then
        echo "Keep Mac Awake is installed on this Mac: during a session it keeps this Mac awake, on AC power only."
    else
        echo "Keep Mac Awake is installed on this Mac: during a session it keeps this MacBook awake with the lid closed."
    fi
    case $phase in
        active)
            if [ "$(field session.unlimited)" = true ]; then echo "A session is running without a time limit."
            elif left=$(number "$(field session.remaining_seconds)"); then echo "A session is running, $(duration "$left") left."
            else echo "A session is running."; fi ;;
        waitingForAC) echo "A session is waiting for AC power." ;;
        idle) echo "No session is running." ;;
        checking|starting|stopping) echo "The session is changing state." ;;
        *) echo "Keep Mac Awake needs attention." ;;
    esac
    hours=$(number "$(field access.max_hours)") || hours=8
    case $(field access.state) in
        trial)
            if [ "$(field access.trial_started)" = true ] && left=$(number "$(field access.trial_seconds_left)"); then
                echo "Trial: $(duration "$left") left; trial sessions last at most $hours hours."
            else
                echo "Trial: 3 days, starting with the first session; trial sessions last at most $hours hours."
            fi ;;
        trialEnded) echo "The trial has ended, so no new session can start." ;;
    esac
    version=$(field update.available_version)
    case $version in
        ''|*[!0-9.]*) ;;
        *) echo "Keep Mac Awake $version is available; the user installs it with Install in the menu bar panel." ;;
    esac
    echo "The keepmacawake skill says when to start and stop a session."
}

# A JSON string body: control characters dropped, backslashes, quotes and tabs
# escaped, lines joined with \n.
json_text() {
    printf '%s' "$1" | /usr/bin/tr -d '\000-\010\013-\037' | /usr/bin/awk 'BEGIN { ORS = "" } { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); if (NR > 1) print "\\n"; print }'
}

# Apple silicon, also under Rosetta (where uname -m says x86_64). Sandboxes such as
# Codex's deny sysctl; uname -m answers there.
arm=$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null) || arm=
[ -n "$arm" ] || { [ "$(uname -m)" = arm64 ] && arm=1; }
[ "$(uname -s)" = Darwin ] && [ "$arm" = 1 ] || exit 0
out=$(state)
case $host in
    cursor) printf '{"additional_context":"%s"}\n' "$(json_text "$out")" ;;
    copilot) printf '{"additionalContext":"%s"}\n' "$(json_text "$out")" ;;
    *) printf '%s\n' "$out" ;;
esac
exit 0
