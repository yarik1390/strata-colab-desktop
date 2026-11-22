#!/usr/bin/env bash
# ==============================================================================
# Open an Interactive Shell or Run a Command on the Colab VM via Multiplexed SSH
# ==============================================================================
# Examples:
#   ./ssh.sh                           # Open an interactive shell on the VM
#   ./ssh.sh nvidia-smi                # Run a command on the VM
#   ./ssh.sh -t tmux attach -t strata  # Attach to the Strata tmux console (Ctrl-b d to detach)
source "$(dirname "$0")/lib/common.sh"

session_exists || die "$(msg runtime_missing_start "$COLAB_SESSION")"

if [[ "${1:-}" != -O ]]; then
    ensure_master || die "$(msg ssh_failed_429)"
fi

opts=()
while [[ $# -gt 0 && "$1" == -* ]]; do
    if [[ "$1" == "-O" && $# -ge 2 ]]; then
        opts+=("$1" "$2")
        shift 2
    else
        opts+=("$1")
        shift
    fi
done

exec ssh "${SSH_OPTS[@]}" "${opts[@]}" "$SSH_HOST" "$@"
