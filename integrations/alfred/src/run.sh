#!/bin/bash
# Runs the action chosen in the Script Filter and prints the message of the
# keepmacawake command, which the workflow shows in a notification.
# Accepts only the actions filter.sh offers.
set -u
cd "$(dirname "$0")" || exit 1
. ./common.sh

action=${1:-}
case "$action" in
    website)
        /usr/bin/open "$KMA_WEBSITE"
        exit 0
        ;;
    status | stop | 'start --unlimited') ;;
    'start --hours '*)
        hours=${action#start --hours }
        case "$hours" in '' | *[!0-9]*) echo 'Pick 1 to 168 hours.'; exit 0 ;; esac
        if [ "${#hours}" -gt 3 ] || [ "$hours" -lt 1 ] || [ "$hours" -gt 168 ]; then
            echo 'Pick 1 to 168 hours.'
            exit 0
        fi
        ;;
    *)
        echo 'Unknown action.'
        exit 0
        ;;
esac

cli=$(kma_cli)
if [ -z "$cli" ]; then
    echo 'Keep Mac Awake is not installed. Get it at keepmacawake.com (free trial).'
    exit 0
fi

# The action is one of the fixed forms above, so splitting it into words is safe.
# shellcheck disable=SC2086
message=$("$cli" $action --no-input 2>&1)
code=$?
if [ -z "$message" ]; then
    case "$code" in
        0) message='Done.' ;;
        6) message='Keep Mac Awake is not running. Open the app and try again.' ;;
        7) message='No answer in time. Check the status: the request may still have completed.' ;;
        *) message="Keep Mac Awake could not do it (exit code $code)." ;;
    esac
fi
printf '%s\n' "$message"
