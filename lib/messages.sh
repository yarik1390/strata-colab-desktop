#!/usr/bin/env bash
# ==============================================================================
# Console Message Catalog (English)
# ==============================================================================
# Provides formatted user-facing messages via `msg <key> [args...]`.

MSG_LANG="en"

declare -A _MSG_EN=(
    # ----- General & SSH -----
    [cmd_missing]="%s not found. Run ./setup-wsl.sh first."
    [no_runtime_skip_ssh]="Runtime %s does not exist, so SSH is skipped."
    [runtime_missing_start]="Runtime %s does not exist. Start it with start.bat or ./up.sh."
    [ssh_no_response]="No response over SSH."
    [ssh_busy_429]="Another colab ssh session is connected to this runtime. Close any manual colab ssh session. Attempt %s/6"
    [ssh_waiting]="Waiting for SSH connection... Attempt %s/6"
    [ssh_failed]="Cannot connect over SSH. Check ssh_config and run ./ssh.sh -v true for details."
    [ssh_failed_429]="Cannot connect over SSH. If another colab ssh session is open, close it (HTTP 429 indicates an active session)."

    # ----- Startup & Recovery -----
    [why_port_in_use]="Strata could not start because port %s is in use"
    [why_setup_exited]="setup.sh exited before Strata was ready"
    [why_not_running]="Strata is not running on Colab"
    [retry_setup]="%s. Retrying setup on Colab (attempt %s/%s)..."
    [retry_exhausted]="%s. Startup failed after %s retries. Check logs with ./logs.sh."
    [start_timeout]="Strata did not start within %s minutes. Check logs with ./logs.sh."
    [strata_unresponsive_redo]="Strata on Colab is not responding. Re-running setup..."

    # ----- Tunnel & Watchdog -----
    [tunnel_already]="The SSH tunnel is already active in another window."
    [local_port_busy]="Local port %s is in use by another process. Change LOCAL_PORT in config.env."
    [tunnel_closed]="Tunnel closed. Unless you stopped the runtime, compute units are still billed. Run stop.bat or ./down.sh to stop the VM."
    [tunnel_failed]="Could not open the SSH port-forwarding tunnel."
    [tunnel_unreachable]="Cannot reach Strata through the local SSH tunnel."
    [ready]="Strata is ready!"
    [tunnel_hold]="The SSH tunnel stays open while this window is running. Press Ctrl+C to disconnect."
    [runtime_stopped]="Runtime %s has stopped."
    [tunnel_stuck]="Strata is running on Colab, but the local tunnel is unresponsive. Reconnecting..."
    [relink_retry_later]="Could not reopen the tunnel. Will retry on the next watchdog check."
    [strata_down_recovering]="Strata on Colab is unresponsive. Attempting automatic recovery..."
    [recovered]="Strata has recovered."

    # ----- Endpoints Display -----
    [ep_webui]="Strata Desktop / WebUI : %s"
    [ep_openai]="OpenAI-Compatible API  : %s"
    [ep_anthropic]="Anthropic Messages API : %s"
    [ep_apikey]="API Key                : %s"
    [ep_apikey_unset]="not set (any string works)"

    # ----- up.sh (Runtime, GPU, Drive & Model Selection) -----
    [units_left]="Google Colab compute units:"
    [runtime_exists]="Runtime %s already exists."
    [runtime_exists_detail]="Active runtime found: %s (GPU: %s / Shape: %s / Endpoint: %s)"
    [runtime_reuse_prompt]="Use this existing runtime? (Enter n to stop it and choose a different GPU) [Y/n] "
    [gpu_menu_header]="Eligible GPUs for your Google Colab account:"
    [gpu_menu_ineligible]="  (Not available on current plan/balance: %s)"
    [gpu_menu_default_tag]=" [default]"
    [gpu_menu_nocap_tag]=" [no capacity right now (503)]"
    [gpu_select_prompt]="Select GPU by number or name [Enter=%s]: "
    [gpu_no_capacity]="Google Colab currently has no available capacity for %s (503 Service Unavailable). Please choose another GPU."
    [gpu_not_entitled]="Your account is not entitled to %s or has insufficient quota. Please choose another GPU."
    [model_menu_header]="Choose a Strata model to run (GPU: %s / Context: %s tokens):"
    [model_select_prompt]="Select model by number [Enter=%s]: "
    [drive_mounting]="Mounting Google Drive at %s to persist downloaded models..."
    [drive_already_mounted]="Google Drive is mounted (model cache: %s)"
    [drive_mount_failed]="Could not mount Google Drive. Continuing with local VM disk only."
    [model_cached_tag]=" [Cached in Google Drive - fast start!]"
    [drive_syncing_progress]="Backing up model to Google Drive: %s"
    [drive_sync_done]="Model backed up to Google Drive (%s). Future runs will restore directly from Drive!"
    [drive_sync_nospace]="Not enough free space on Google Drive (need %s GB, %s GB free); skipped Drive backup."
    [down_waiting_drive_sync]="Waiting for Google Drive model backup to finish (press Ctrl+C to abort and stop immediately): %s"
    [runtime_creating]="Creating Colab runtime: %s"
    [ssh_connecting]="Connecting to Colab VM over SSH..."
    [gpu_line]="Allocated GPU: %s"
    [gpu_unknown]="unknown"
    [gpu_mismatch]="Allocated GPU does not match expected pattern (%s)."
    [gpu_continue_prompt]="Continue anyway? [y/N] "
    [stopping_to_save]="Stopping runtime to save compute units..."
    [gpu_aborted]="Aborted. Try again later or change GPU in config.env."
    [preparing]="Preparing Strata on the Colab VM..."
    [waiting_start]="Waiting for Strata to start (first run downloads model weights; cached Drive models start in a few minutes)..."
    [started]="Strata has started!"

    # ----- restart.sh -----
    [rs_closing_window]="Closing the tunnel held by start.bat so the previous watchdog does not revert to old settings..."
    [rs_restarting]="Reloading config.env and restarting Strata on Colab (keeping the active runtime and downloaded models)..."
    [rs_waiting]="Waiting for Strata to restart..."

    # ----- down.sh -----
    [closing_tunnel]="Closing local SSH tunnel..."
    [down_syncing_config]="Saving tuned Strata presets and configs to Google Drive..."
    [stopping_runtime]="Stopping Colab runtime %s..."
    [runtime_already_gone]="Runtime %s was not found (already stopped)."
    [usage_after_stop]="Account usage status (Active assignments: 0 confirms all VMs are stopped):"

    # ----- status.sh -----
    [st_runtime]="== Colab Runtime: %s =="
    [st_vm]="== Colab VM Hardware & Disk =="
    [st_ssh_fail]="Cannot connect over SSH"
    [st_strata_up]="Strata Status: RUNNING"
    [st_strata_down]="Strata Status: STOPPED or STARTING (check ./logs.sh)"
    [st_drive]="== Google Drive Model Cache: %s =="
    [st_none]="No active runtime"
    [st_tunnel]="== Local SSH Tunnel: http://localhost:%s =="
    [st_connected]="Connected"
    [st_disconnected]="Not connected"
    [st_units]="== Compute Units =="

    # ----- setup-wsl.sh -----
    [sw_apt]="== Installing apt packages: openssh-client, curl, iproute2 =="
    [sw_uv]="== Installing uv package manager =="
    [sw_colab]="== Installing Google Colab CLI (with headless keyring support) =="
    [sw_key]="== Generating Ed25519 SSH key for Colab VM tunneling =="
    [sw_key_exists]="Using existing SSH key at ~/.ssh/id_ed25519."
    [sw_done]="\nSetup complete! Next steps:\n  1. Run 'colab usage' to sign in to your Google account (if not already signed in).\n  2. Review or customize settings in config.env if desired.\n  3. Double-click start.bat on Windows (or run ./up.sh in WSL) to launch Strata Desktop!\n"

    # ----- Remote VM (remote-setup.sh) -----
    [r_already_running]="Strata is already running."
    [r_redo]="Re-running setup..."
    [r_restart]="Stopping running Strata instance and restarting with updated settings..."
    [r_prev_exited]="Previous setup.sh process exited. Restarting..."
    [r_port_fail_restart]="Previous startup failed because port %s was busy. Restarting..."
    [r_in_progress]="Setup or startup is already in progress. Waiting for completion..."
    [r_installing]="Installing %s..."
    [r_stop_old]="Stopping previous Strata processes: %s"
    [r_port_other]="Port %s is held by a non-Strata process. Aborting without killing it:"
    [r_port_other_hint]="Change REMOTE_PORT in config.env to another port and run again."
    [r_cloning]="Cloning Strata repository: %s"
    [r_py_install]="No Python with venv support found. Installing python3-venv..."
    [r_py_missing]="No Python 3.10+ with venv support was found."
    [r_py]="Python runtime for Strata: %s (%s)"
    [r_port_fixed]="Updated port in %s from %s to %s."
    [r_started]="Started Strata (%s mode) in tmux: model=%s / context=%s / port=%s"
    [r_hf_install]="Installing Hugging Face download CLI (huggingface_hub[hf_xet])..."
    [r_custom_inspect]="Verifying that %s (%s) is compatible with Strata (reading headers only)..."
    [r_custom_unsupported]="%s (%s) is not supported by Strata. Check MODEL_REPO, MODEL, and MODEL_FILES in config.env."
    [r_custom_inspect_unknown]="Header inspection returned exit code %s; continuing anyway..."
    [r_custom_nofiles]="No files in %s matched pattern %s. Check MODEL_FILES in config.env."
    [r_custom_multidir]="Files matching %s span multiple subdirectories. Narrow MODEL_FILES to a single folder."
    [r_custom_disk]="Insufficient disk space: download requires %s GB, but only %s GB is free."
    [r_custom_lookup_failed]="Could not query repository %s. Check MODEL_REPO, MODEL_REVISION, and HF_TOKEN (if private)."
    [r_custom_ready]="All custom GGUF files from %s are already present."
    [r_custom_plan]="Downloading %s (%s files) into %s: %s GB needed, %s GB free."
)

msg() {
    local key="$1" fmt
    shift
    fmt="${_MSG_EN[$key]-}"
    [[ -n "$fmt" ]] || fmt="[$key]"
    # shellcheck disable=SC2059
    printf "$fmt" "$@"
}
