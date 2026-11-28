#!/usr/bin/env bash
# ==============================================================================
# One-Time WSL2 Ubuntu Environment Setup
# ==============================================================================
# Installs OpenSSH client, curl, iproute2, uv, google-colab-cli (with headless
# keyring support for WSL), and generates a passwordless Ed25519 SSH key.
set -euo pipefail

# shellcheck source=lib/messages.sh
source "$(dirname "$0")/lib/messages.sh"

msg sw_apt; echo
sudo apt-get update -qq
sudo apt-get install -y -qq openssh-client curl iproute2

export PATH="$HOME/.local/bin:$PATH"

msg sw_uv; echo
if ! command -v uv >/dev/null 2>&1; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
fi
uv --version

msg sw_colab; echo
uv tool install --force --with keyrings.alt google-colab-cli
mkdir -p "$HOME/.config/python_keyring"
KEYRING_CFG="$HOME/.config/python_keyring/keyringrc.cfg"
if [[ -f "$KEYRING_CFG" && "${FORCE_KEYRING_CONFIG:-0}" != 1 ]]; then
    msg sw_keyring_exists "$KEYRING_CFG"; echo
else
    cat > "$KEYRING_CFG" << 'EOF'
[backend]
default-keyring=keyrings.alt.file.PlaintextKeyring
EOF
    msg sw_keyring_written "$KEYRING_CFG"; echo
fi

msg sw_key; echo
if [[ ! -f "$HOME/.ssh/id_ed25519" ]]; then
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" -C "strata-colab-desktop"
else
    msg sw_key_exists; echo
fi

msg sw_done
