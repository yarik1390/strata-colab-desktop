#!/usr/bin/env bash
# ==============================================================================
# Display Colab Runtime, Hardware, Strata Status, Drive Cache & Tunnel State
# ==============================================================================
source "$(dirname "$0")/lib/common.sh"

require_cmds colab ssh curl

if py="$(colab_python 2>/dev/null)"; then
    "$py" "$ROOT/lib/colab-helper.py" adopt "$COLAB_SESSION" >/dev/null 2>&1 || true
fi

msg st_runtime "$COLAB_SESSION"; echo
if session_exists; then
    colab status -s "$COLAB_SESSION" | sed 's/^/    /'

    msg st_vm; echo
    rssh "nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader; free -g | sed -n 2p; df -h /content | tail -n 1" \
        2>/dev/null | sed 's/^/    /' || echo "    $(msg st_ssh_fail)"
    if remote_healthy; then
        echo "    $(msg st_strata_up)"
    else
        echo "    $(msg st_strata_down)"
    fi

    if [[ "${USE_DRIVE:-1}" == 1 ]]; then
        msg st_drive "$DRIVE_DATA_DIR"; echo
        q_dd="$(printf '%q' "$DRIVE_DATA_DIR")"
        rssh "if [[ -d $q_dd ]]; then find $q_dd -name '*.gguf' -exec ls -lh {} + 2>/dev/null | awk '{print \$9, \"(\" \$5 \")\"}'; if [[ -d $q_dd/strata-config ]]; then for g in $q_dd/strata-config/*; do [[ -d \"\$g\" ]] || continue; n=\$(find \"\$g/presets\" -maxdepth 1 -name '*.json' ! -name 'active.json' 2>/dev/null | wc -l); echo \"Config [\$(basename \"\$g\")]: \$n tuned preset(s)\"; done; fi; else echo 'Not mounted or empty'; fi; [[ -f /tmp/strata-drive-sync.status ]] && echo \"Sync status: \$(cat /tmp/strata-drive-sync.status)\"; [[ -f /tmp/strata-config-sync.status ]] && echo \"Config sync: \$(cat /tmp/strata-config-sync.status)\"" \
            2>/dev/null | sed 's/^/    /' || true
    fi
else
    echo "    $(msg st_none)"
fi

msg st_tunnel "$LOCAL_PORT"; echo
if local_healthy; then echo "    $(msg st_connected)"; else echo "    $(msg st_disconnected)"; fi

msg st_units; echo
colab usage | sed 's/^/    /'
