#!/bin/bash
# Builds the Keep Mac Awake shortcuts from the shell scripts in this file,
# without the Shortcuts app: each one is a "Run Shell Script" action that runs
# the keepmacawake command, then "Show Result" with its message. Writes
# unsigned .shortcut files; with --sign, also signed copies (shortcuts sign
# --mode anyone, which needs an Apple Account signed in on this Mac).
#
# Usage: build.sh [output directory] [--sign]   (default: ./build)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out="$here/build"
sign=0
for arg in "$@"; do
    case "$arg" in
        --sign) sign=1 ;;
        -*) echo "Usage: build.sh [output directory] [--sign]" >&2; exit 2 ;;
        *) out=$arg ;;
    esac
done
mkdir -p "$out"

# The script of each shortcut. It shows the command's message whatever its
# exit code, and a short note when Keep Mac Awake is not installed.
script_for() {
    cat <<SCRIPT
cli=/usr/local/bin/keepmacawake
if [ ! -x "\$cli" ]; then
  echo "Keep Mac Awake is not installed. Get it at keepmacawake.com (free trial)."
  exit 0
fi
"\$cli" $1 --no-input 2>&1
exit 0
SCRIPT
}

# Writes one unsigned shortcut. Arguments: file name, keepmacawake arguments,
# icon color, icon glyph, the UUID of the shell action.
build_one() {
    local name=$1 args=$2 color=$3 glyph=$4 uuid=$5
    local plist="$out/$name.unsigned.plist" target="$out/$name.shortcut"
    rm -f "$plist" "$target"
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>WFQuickActionSurfaces</key>
	<array/>
	<key>WFWorkflowActions</key>
	<array>
		<dict>
			<key>WFWorkflowActionIdentifier</key>
			<string>is.workflow.actions.runshellscript</string>
			<key>WFWorkflowActionParameters</key>
			<dict>
				<key>InputMode</key>
				<string>to stdin</string>
				<key>Script</key>
				<string></string>
				<key>Shell</key>
				<string>/bin/zsh</string>
				<key>UUID</key>
				<string>$uuid</string>
			</dict>
		</dict>
		<dict>
			<key>WFWorkflowActionIdentifier</key>
			<string>is.workflow.actions.showresult</string>
			<key>WFWorkflowActionParameters</key>
			<dict>
				<key>Text</key>
				<dict>
					<key>Value</key>
					<dict>
						<key>attachmentsByRange</key>
						<dict>
							<key>{0, 1}</key>
							<dict>
								<key>OutputName</key>
								<string>Shell Script Result</string>
								<key>OutputUUID</key>
								<string>$uuid</string>
								<key>Type</key>
								<string>ActionOutput</string>
							</dict>
						</dict>
						<key>string</key>
						<string>&#xFFFC;</string>
					</dict>
					<key>WFSerializationType</key>
					<string>WFTextTokenString</string>
				</dict>
			</dict>
		</dict>
	</array>
	<key>WFWorkflowClientVersion</key>
	<string>2302.0.4</string>
	<key>WFWorkflowHasOutputFallback</key>
	<false/>
	<key>WFWorkflowHasShortcutInputVariables</key>
	<false/>
	<key>WFWorkflowIcon</key>
	<dict>
		<key>WFWorkflowIconGlyphNumber</key>
		<integer>$glyph</integer>
		<key>WFWorkflowIconStartColor</key>
		<integer>$color</integer>
	</dict>
	<key>WFWorkflowImportQuestions</key>
	<array/>
	<key>WFWorkflowInputContentItemClasses</key>
	<array/>
	<key>WFWorkflowMinimumClientVersion</key>
	<integer>900</integer>
	<key>WFWorkflowMinimumClientVersionString</key>
	<string>900</string>
	<key>WFWorkflowOutputContentItemClasses</key>
	<array/>
	<key>WFWorkflowTypes</key>
	<array/>
</dict>
</plist>
PLIST
    /usr/bin/plutil -replace 'WFWorkflowActions.0.WFWorkflowActionParameters.Script' -string "$(script_for "$args")" "$plist"
    /usr/bin/plutil -lint -s "$plist"
    /usr/bin/plutil -convert binary1 -o "$target" "$plist"
    rm -f "$plist"
    if [ "$sign" = 1 ]; then
        /usr/bin/shortcuts sign --mode anyone --input "$target" --output "$out/$name.signed.shortcut"
    fi
    echo "Built $target"
}

# Icon colors and glyphs are the Shortcuts app's own codes.
build_one 'Keep Mac Awake - start 8 hours' 'start --hours 8' 4282601983 59446 'A3C4D2E1-6B7A-4F80-9C1D-2E3F4A5B6C01'
build_one 'Keep Mac Awake - status' 'status' 4282601983 59511 'A3C4D2E1-6B7A-4F80-9C1D-2E3F4A5B6C02'
build_one 'Keep Mac Awake - stop' 'stop' 4282601983 59494 'A3C4D2E1-6B7A-4F80-9C1D-2E3F4A5B6C03'
