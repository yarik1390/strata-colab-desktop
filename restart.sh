#!/usr/bin/env bash
# ==============================================================================
# Restart Strata on the Active Colab Runtime After Changing config.env
# ==============================================================================
# Keeps the active Colab VM and downloaded models intact.
source "$(dirname "$0")/lib/common.sh"

require_cmds colab ssh curl ss
adopt_existing_session
session_exists || die "$(msg runtime_missing_start "$COLAB_SESSION")"

if [[ -f "$TUNNEL_PID_FILE" ]]; then
    log "$(msg rs_closing_window)"
    stop_tunnel
fi

emit_ui_state "starting"
log "$(msg rs_restarting)"
remote_start 2
log "$(msg rs_waiting)"
wait_healthy
log "$(msg started)"

run_tunnel_foreground
