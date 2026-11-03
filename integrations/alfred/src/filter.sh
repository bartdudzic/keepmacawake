#!/bin/bash
# Script Filter of the Keep Mac Awake workflow for Alfred.
# Shows the session state from `keepmacawake status` and the actions that fit
# what was typed: start for 1 hour, 8 hours, N hours or with no time limit,
# show the status, stop. It only reads; run.sh runs the chosen action.
set -u
cd "$(dirname "$0")" || exit 1
. ./common.sh

query=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | sed -e 's/^ *//' -e 's/ *$//')
items=()

# One result. Arguments: title, subtitle, and the argument for run.sh
# (empty for a result that only informs).
add_item() {
    local item="{\"title\":$(kma_json "$1"),\"subtitle\":$(kma_json "$2")"
    if [ -n "$3" ]; then
        item+=",\"arg\":$(kma_json "$3"),\"valid\":true"
    else
        item+=",\"valid\":false"
    fi
    items+=("$item,\"icon\":{\"path\":\"icon.png\"}}")
}

# True when every word typed starts a word of the given text.
matches() {
    local text=" $1" word
    for word in $query; do
        case "$text" in *" $word"*) ;; *) return 1 ;; esac
    done
    return 0
}

print_items() {
    local joined='' item
    for item in "${items[@]}"; do joined+="${joined:+,}$item"; done
    printf '{"items":[%s]}\n' "$joined"
}

cli=$(kma_cli)
if [ -z "$cli" ]; then
    add_item 'Keep Mac Awake is not installed' \
        'This workflow needs the Keep Mac Awake app. Press Return to open keepmacawake.com (free trial).' 'website'
    print_items
    exit 0
fi

status=$("$cli" status --no-input --timeout 5 2>&1)
code=$?
first=$(printf '%s\n' "$status" | sed -n '1p')
rest=$(printf '%s\n' "$status" | sed -n '2,$p' | tr '\n' ' ' | sed 's/ *$//')
if [ "$code" -eq 6 ]; then
    add_item 'Keep Mac Awake is not running' "${first:-Open the Keep Mac Awake app.}" ''
    print_items
    exit 0
fi
[ -n "$first" ] || first='Keep Mac Awake did not answer.'

# A number of hours: "3", "3h", "3 hours", "start 3".
number=$(printf '%s' "$query" | sed -E -n 's/^(start +)?([0-9]+) *(h|hour|hours)?$/\2/p')
if [ -n "$number" ]; then
    hours=$(printf '%s' "$number" | sed 's/^0*//')
    if [ -n "$hours" ] && [ "${#hours}" -le 3 ] && [ "$hours" -le 168 ]; then
        unit=hours
        [ "$hours" -eq 1 ] && unit=hour
        add_item "Keep this Mac awake for $hours $unit" 'Starts a session that ends on its own.' "start --hours $hours"
    else
        add_item 'Pick 1 to 168 hours' 'A timed session lasts 1 to 168 whole hours.' ''
    fi
    add_item "$first" "${rest:-Press Return to show the status.}" 'status'
    print_items
    exit 0
fi

matches 'status show state' &&
    add_item "$first" "${rest:-Press Return to show the status.}" 'status'
matches 'start keep awake for 1 one hour' &&
    add_item 'Keep this Mac awake for 1 hour' 'Starts a session that ends on its own.' 'start --hours 1'
matches 'start keep awake for 8 eight hours overnight' &&
    add_item 'Keep this Mac awake for 8 hours' 'Starts a session that ends on its own.' 'start --hours 8'
matches 'start keep awake for custom number of hours' &&
    add_item 'Keep this Mac awake for a number of hours' 'Type the hours after the keyword, 1 to 168.' ''
matches 'start keep awake with no time limit unlimited' &&
    add_item 'Keep this Mac awake with no time limit' 'Runs until you stop it or quit the app.' 'start --unlimited'
matches 'stop turn off end session' &&
    add_item 'Stop the session' 'This Mac sleeps as usual again.' 'stop'
[ "${#items[@]}" -gt 0 ] || add_item 'No matching action' 'Type start, a number of hours, status or stop.' ''
print_items
