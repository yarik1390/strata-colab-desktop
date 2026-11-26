#!/usr/bin/env bash
# Open a URL in the host Windows default browser cleanly (without cmd.exe '&' truncation).
set -euo pipefail

url="${1:-}"
[[ -n "$url" ]] || exit 0

# When hosted inside the Strata Windows WPF launcher, the UI process opens the URL directly.
if [[ "${STRATA_UI_HOST:-0}" == 1 ]]; then
    exit 0
fi

if command -v powershell.exe >/dev/null 2>&1; then
    (
        cd /mnt/c 2>/dev/null || true
        export STRATA_OPEN_URL="$url"
        export WSLENV="STRATA_OPEN_URL${WSLENV:+:$WSLENV}"
        powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden \
            -Command 'Start-Process -FilePath $env:STRATA_OPEN_URL' >/dev/null 2>&1
    )
    exit $?
fi

if command -v wslview >/dev/null 2>&1; then
    wslview "$url" >/dev/null 2>&1 &
    exit 0
fi

if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1 &
    exit 0
fi

exit 1
