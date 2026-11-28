#!/usr/bin/env bash
# ==============================================================================
# Stream Live Setup & Strata Server Logs from the Colab VM (Ctrl+C to exit)
# ==============================================================================
source "$(dirname "$0")/lib/common.sh"

adopt_existing_session
session_exists || die "$(msg runtime_missing_start "$COLAB_SESSION")"
rssh_direct "tail -n 50 -F $(printf '%q' "$REMOTE_LOG")"
