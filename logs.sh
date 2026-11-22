#!/usr/bin/env bash
# ==============================================================================
# Stream Live Setup & Strata Server Logs from the Colab VM (Ctrl+C to exit)
# ==============================================================================
source "$(dirname "$0")/lib/common.sh"

rssh "tail -n 50 -F $(printf '%q' "$REMOTE_LOG")"
