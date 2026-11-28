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
adopt_existing_session

if session_exists; then
    # If a Google Drive model backup is currently in flight, wait for completion (Ctrl+C skips waiting).
    # Verify the backup process is actually alive and enforce a bounded max wait so stale status never hangs.
    if [[ "${USE_DRIVE:-1}" == 1 ]]; then
        if [[ "${DRIVE_MODEL_CACHE:-0}" == 1 ]]; then
            max_wait_sec="${DOWN_DRIVE_SYNC_MAX_WAIT_SEC:-1800}"
            waited_sec=0
            while true; do
                sync_probe="$(rssh "if pgrep -f '[s]trata-drive-cache.py backup' >/dev/null 2>&1; then echo ALIVE; else echo DEAD; fi; cat /tmp/strata-drive-sync.status 2>/dev/null || true" 2>/dev/null || true)"
                proc_state="$(sed -n '1p' <<<"$sync_probe")"
                dstat="$(sed -n '2p' <<<"$sync_probe")"
                case "$dstat" in
                    SYNCING:*)
                        if [[ "$proc_state" != "ALIVE" ]]; then
                            warn "$(msg down_drive_sync_stale)"
                            break
                        fi
                        if (( waited_sec >= max_wait_sec )); then
                            warn "$(msg down_drive_sync_timeout "$max_wait_sec")"
                            break
                        fi
                        log "$(msg down_waiting_drive_sync "${dstat#SYNCING:}")"
                        sleep 5 || break
                        waited_sec=$((waited_sec + 5))
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
