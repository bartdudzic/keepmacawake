#!/bin/bash
# Fails when the public tree contains anything that must stay private:
# non-English text, private documents, business terms, keys and secrets,
# payment and hosting account IDs, chip names of Macs (public texts name no
# tested Mac), local paths, e-mail addresses other than the public contact,
# or unfilled markers.
set -euo pipefail
cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}"

status=0
# Tracked files when this directory is the root of its own repository,
# otherwise every file under it (for example an export before the first commit).
files() {
    if [ "$(git rev-parse --show-toplevel 2>/dev/null)" = "$(pwd -P)" ]; then
        git ls-files -z -- . ':!scripts/scan-public-content.sh'
    else
        find . -type f ! -path './.git/*' ! -path './.build/*' ! -path './scripts/scan-public-content.sh' -print0
    fi
}
check() {
    local label=$1 pattern=$2 flags=$3 allowed=${4:-'^$'}
    local matches
    matches=$(files | xargs -0 grep -nIE $flags -- "$pattern" 2>/dev/null | grep -vE "$allowed" || true)
    if [ -n "$matches" ]; then
        echo "$label:" >&2
        echo "$matches" | head -50 >&2
        status=1
    fi
}

# Patterns are built from UTF-8 bytes so this file stays ASCII.
polish=$(printf '(\xc4\x85|\xc4\x87|\xc4\x99|\xc5\x82|\xc5\x84|\xc3\xb3|\xc5\x9b|\xc5\xba|\xc5\xbc|\xc4\x84|\xc4\x86|\xc4\x98|\xc5\x81|\xc5\x83|\xc3\x93|\xc5\x9a|\xc5\xb9|\xc5\xbb)')
dashes=$(printf '(\xe2\x80\x94|\xe2\x80\x93)')
check 'Polish characters' "$polish" ''
check 'Dashes U+2014 or U+2013' "$dashes" ''
check 'Private documents' 'docs/(superpowers|decisions|testing|research|operations|content|reference)|agent-handoff|compatibility\.md|BartOS' '-i'
check 'Business terms' '\b(paddle|gumroad|lemon ?squeezy|pricing|marketing|competitors?|research|license key|entitlement)\b' '-i'
check 'Keys and secrets' '-----BEGIN [A-Z ]*PRIVATE KEY|\b(sk|rk|pk)_(live|test)_[A-Za-z0-9]|\bwhsec_[A-Za-z0-9]|"d" *: *"[A-Za-z0-9_-]{16,}|\bgh[pousr]_[A-Za-z0-9]{20,}|\bgithub_pat_|\bAKIA[0-9A-Z]{16}\b|\bxox[abpr]-' ''
check 'Account IDs' '\b(price|prod|acct|cus)_[A-Za-z0-9]{14,}|\b(cs|pi)_(live|test)_|\bphc_[A-Za-z0-9]{20,}|\.workers\.dev' ''
check 'Mac chip names' '\bM[1-9]( (Pro|Max|Ultra))?\b' ''
check 'Local paths' '/Users/|/private/var/|/var/folders/' ''
check 'E-mail addresses' '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' '' 'hi@keepmacawake\.com|git@github\.com'
check 'Unfilled markers' 'OWNER-TODO|TODO-OWNER' ''

[ "$(files | tr -cd '\0' | wc -c)" -gt 0 ] || { echo 'No files to scan.' >&2; exit 1; }
if [ "$status" -eq 0 ]; then echo 'Content scan passed.'; fi
exit "$status"
