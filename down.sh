#!/usr/bin/env bash
# ==============================================================================
# Close Local Tunnel, Wait for Active Google Drive Backup & Stop Colab Runtime
# ==============================================================================
source "$(dirname "$0")/lib/common.sh"

require_cmds colab

if [[ -f "$TUNNEL_PID_FILE" ]]; then
    log "$(msg closing_tunnel)"
    stop_tunnel
fi
close_link
stop_workload_monitor

# Adopt any orphaned server-side assignment before stopping
if py="$(colab_python 2>/dev/null)"; then
    "$py" "$ROOT/lib/colab-helper.py" adopt "$COLAB_SESSION" >/dev/null 2>&1 || true
fi

if session_exists; then
    # If a Google Drive model backup is currently in flight, wait for completion (Ctrl+C skips waiting)
    if [[ "${USE_DRIVE:-1}" == 1 ]]; then
        if [[ "${DRIVE_MODEL_CACHE:-0}" == 1 ]]; then
            while true; do
                dstat="$(rssh "cat /tmp/strata-drive-sync.status 2>/dev/null" 2>/dev/null || true)"
                case "$dstat" in
                    SYNCING:*)
                        log "$(msg down_waiting_drive_sync "${dstat#SYNCING:}")"
                        sleep 5 || break
                        ;;
                    *)
                        break
                        ;;
                esac
            done
        fi
        log "$(msg down_syncing_config)"
        rssh "if [[ -f /tmp/strata-drive-cache.py ]]; then python3 /tmp/strata-drive-cache.py sync-config $(printf '%q ' "$DRIVE_DATA_DIR" "$REMOTE_DIR") || true; fi" 2>/dev/null || true
    fi
    stop_master
    log "$(msg stopping_runtime "$COLAB_SESSION")"
    colab stop -s "$COLAB_SESSION"
else
    stop_master
    log "$(msg runtime_already_gone "$COLAB_SESSION")"
fi

log "$(msg usage_after_stop)"
colab usage | sed 's/^/    /'
