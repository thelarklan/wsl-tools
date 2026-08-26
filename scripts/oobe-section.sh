#!/usr/bin/env bash
set -Eeuo pipefail

# Print the body of the [oobe] section of a WSL distribution configuration file.
# Callers grep this instead of the whole file so a `command` or `defaultUid` key
# belonging to another section, which WSL never reads as an OOBE setting, cannot
# satisfy or break a check. A missing file prints nothing and succeeds; deciding
# what that means is the caller's job.
path="${1:?usage: oobe-section.sh PATH}"
[[ -f ${path} ]] || exit 0

awk '
    /^[[:space:]]*\[/ {
        in_oobe = ($0 ~ /^[[:space:]]*\[[[:space:]]*oobe[[:space:]]*\][[:space:]]*$/)
        next
    }
    in_oobe { print }
' "${path}"
