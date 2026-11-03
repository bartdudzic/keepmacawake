# Shared by filter.sh and run.sh. Finds the keepmacawake command and runs it.
# Alfred starts scripts with a short PATH, so the installer's location comes first.

KMA_DEFAULT_CLI=/usr/local/bin/keepmacawake
KMA_WEBSITE='https://keepmacawake.com/?utm_source=alfred&utm_medium=referral&utm_campaign=alfred-workflow&utm_content=not-installed'

# Prints the command's path, or nothing when Keep Mac Awake is not installed.
# KEEPMACAWAKE_CLI, when set (also when empty), is the only path tried: the
# tests set it to a fake command, so they can never reach the real one.
kma_cli() {
    if [ -n "${KEEPMACAWAKE_CLI+set}" ]; then
        [ -n "$KEEPMACAWAKE_CLI" ] && [ -x "$KEEPMACAWAKE_CLI" ] && printf '%s\n' "$KEEPMACAWAKE_CLI"
        return 0
    elif [ -x "$KMA_DEFAULT_CLI" ]; then
        printf '%s\n' "$KMA_DEFAULT_CLI"
    else
        command -v keepmacawake 2>/dev/null || true
    fi
}

# A value as a JSON string: backslashes, quotes and line breaks escaped,
# other control characters dropped.
kma_json() {
    local value
    value=$(printf '%s' "$1" | LC_ALL=C tr -d '\000-\010\013\014\016-\037')
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\r'/}
    value=${value//$'\t'/ }
    value=${value//$'\n'/\\n}
    printf '"%s"' "$value"
}
