#!/usr/bin/env bash
# ==============================================================================
# Open an Interactive Shell or Run a Command on the Colab VM via Multiplexed SSH
# ==============================================================================
# Examples:
#   ./ssh.sh                           # Open an interactive shell on the VM
#   ./ssh.sh nvidia-smi                # Run a command on the VM
#   ./ssh.sh -t tmux attach -t strata  # Attach to the Strata tmux console (Ctrl-b d to detach)
source "$(dirname "$0")/lib/common.sh"

adopt_existing_session
session_exists || die "$(msg runtime_missing_start "$COLAB_SESSION")"

opts=()
has_ctl_opt=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --)
            shift
            break
            ;;
        -O)
            has_ctl_opt=1
            if [[ $# -ge 2 ]]; then
                opts+=("$1" "$2")
                shift 2
            else
                opts+=("$1")
                shift
            fi
            ;;
        -B|-b|-c|-D|-E|-e|-F|-I|-i|-J|-L|-l|-m|-o|-p|-Q|-R|-S|-W|-w)
            if [[ $# -ge 2 ]]; then
                opts+=("$1" "$2")
                shift 2
            else
                opts+=("$1")
                shift
            fi
            ;;
        -*)
            opts+=("$1")
            shift
            ;;
        *)
            break
            ;;
    esac
done

if (( has_ctl_opt == 0 )); then
    ensure_master || die "$(msg ssh_failed_429)"
fi

exec ssh "${SSH_OPTS[@]}" "${opts[@]}" "$SSH_HOST" "$@"
