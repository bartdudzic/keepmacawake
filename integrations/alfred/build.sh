#!/bin/bash
# Builds Keep-Mac-Awake.alfredworkflow from src/ without Alfred:
# copies the sources and the icon, puts README.md and the version into
# info.plist, checks the plist with plutil, and zips the files in a fixed
# order with fixed dates, so the same sources give the same file.
#
# Usage: build.sh [output directory]   (default: ./build)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-"$here/build"}
version=$(/usr/bin/plutil -extract version raw -o - "$here/src/info.plist")
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

cp "$here/src/info.plist" "$here/src/filter.sh" "$here/src/run.sh" "$here/src/common.sh" "$stage/"
cp "$here/../../plugins/keep-mac-awake/assets/icon.png" "$stage/icon.png"
# The workflow's About text is the README from Usage up to Build.
/usr/bin/plutil -replace readme -string "$(sed -e '1,/^## Usage/{/^## Usage/!d;}' -e '/^## Build/,$d' "$here/README.md")" "$stage/info.plist"
/usr/bin/plutil -lint -s "$stage/info.plist"
for script in filter.sh run.sh; do
    /bin/bash -n "$stage/$script"
    chmod 755 "$stage/$script"
done
chmod 644 "$stage/info.plist" "$stage/common.sh" "$stage/icon.png"
# Every object's script file must be in the bundle.
grep -A1 '<key>scriptfile</key>' "$stage/info.plist" | sed -n 's|.*<string>\(.*\)</string>.*|\1|p' | while read -r file; do
    [ -f "$stage/$file" ] || { echo "Missing script file: $file" >&2; exit 1; }
done

mkdir -p "$out"
out=$(cd "$out" && pwd)  # absolute, so the zip below, run inside the staging folder, writes where the caller asked
target="$out/Keep-Mac-Awake.alfredworkflow"
rm -f "$target"
TZ=UTC touch -t 202601010000 "$stage"/*
(cd "$stage" && TZ=UTC /usr/bin/zip -q -X -D "$target" common.sh filter.sh icon.png info.plist run.sh)
echo "Built $target (version $version)"
