#!/usr/bin/env bash
# ==============================================================================
# Re-establish Local SSH Port-Forwarding Tunnel to an Active Colab Runtime
# ==============================================================================
source "$(dirname "$0")/lib/common.sh"

require_cmds colab ssh curl ss
session_exists || die "$(msg runtime_missing_start "$COLAB_SESSION")"
if ! remote_healthy; then
    warn "$(msg strata_unresponsive_redo)"
    remote_start 0
    wait_healthy
fi
run_tunnel_foreground
