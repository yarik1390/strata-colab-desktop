#!/usr/bin/env bash
# ==============================================================================
# Shared Configuration Loader, SSH Multiplexing & Tunnel Management
# ==============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$ROOT/.state"
TUNNEL_PID_FILE="$STATE_DIR/tunnel.pid"
WORKLOAD_PID_FILE="$STATE_DIR/workload-monitor.pid"
WORKLOAD_LOG_FILE="$STATE_DIR/workload-monitor.log"
mkdir -p "$STATE_DIR"

declare -A _CALLER_ENV=()
for _k in GPU ASK_GPU MODEL ASK_MODEL MODEL_FAMILY CONTEXT UI_MODE OPEN_BROWSER; do
    if [[ -n "${!_k:-}" ]]; then
        _CALLER_ENV["$_k"]="${!_k}"
    fi
done

# Strip CR characters before sourcing so editing config.env on Windows never introduces trailing \r values
# shellcheck disable=SC1090
load_config() { source <(tr -d '\r' < "$1"); }
load_config "$ROOT/config.env"
if [[ -f "$ROOT/config.local.env" ]]; then
    load_config "$ROOT/config.local.env"
fi
for _k in "${!_CALLER_ENV[@]}"; do
    printf -v "$_k" '%s' "${_CALLER_ENV[$_k]}"
done
unset _CALLER_ENV _k
# shellcheck source=messages.sh
source "$ROOT/lib/messages.sh"

# Default fallback values
HF_TOKEN="${HF_TOKEN:-}"
MODEL_FAMILY="${MODEL_FAMILY:-}"
MODEL_REPO="${MODEL_REPO:-}"
MODEL_FILES="${MODEL_FILES:-}"
MODEL_REVISION="${MODEL_REVISION:-}"
USE_DRIVE="${USE_DRIVE:-1}"
DRIVE_MOUNT="${DRIVE_MOUNT:-/content/drive}"
DRIVE_DATA_DIR="${DRIVE_DATA_DIR:-/content/drive/MyDrive/Strata-data}"
UI_MODE="${UI_MODE:-desktop}"
TUNE_ON_START="${TUNE_ON_START:-0}"
ACTIVE_WORKLOAD_MONITOR="${ACTIVE_WORKLOAD_MONITOR:-1}"

export COLAB_SESSION
command -v colab >/dev/null 2>&1 || export PATH="$HOME/.local/bin:$PATH"

SSH_HOST="${SSH_HOST:-colab-strata}"
SSH_OPTS=(-F "$ROOT/ssh_config")
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[33m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '\033[31m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

require_cmds() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "$(msg cmd_missing "$c")"
    done
}

colab_python() {
    local colab_bin py
    if [[ -x "$HOME/.local/share/uv/tools/google-colab-cli/bin/python" ]]; then
        echo "$HOME/.local/share/uv/tools/google-colab-cli/bin/python"
        return 0
    fi
    colab_bin="$(command -v colab 2>/dev/null || true)"
    if [[ -n "$colab_bin" ]]; then
        py="$(head -n 1 "$colab_bin" | sed 's/^#!//; s/[[:space:]]*$//')"
        [[ -x "$py" ]] && { echo "$py"; return 0; }
    fi
    return 1
}

# Check whether the Colab session exists on the backend
session_exists() {
    local out
    out="$(colab status -s "$COLAB_SESSION" </dev/null 2>&1)" || return 1
    ! grep -qi "not found" <<<"$out"
}

# Control the shared OpenSSH ControlMaster connection
ctl() { ssh "${SSH_OPTS[@]}" -O "$1" "${@:2}" "$SSH_HOST"; }

# Establish the shared SSH ControlMaster connection if not already running.
# Redirect stdin from /dev/null so ProxyCommand never consumes piped script input.
ensure_master() {
    ctl check >/dev/null 2>&1 && return 0
    (
        flock 9
        ctl check >/dev/null 2>&1 && exit 0
        setsid -w ssh "${SSH_OPTS[@]}" -o ControlMaster=yes -N -f "$SSH_HOST" </dev/null
    ) 9>"$HOME/.ssh/colab-cm-$COLAB_SESSION.lock"
}

# Execute a command on the Colab VM over the multiplexed SSH connection
rssh() {
    if ! session_exists; then
        warn "$(msg no_runtime_skip_ssh "$COLAB_SESSION")"
        return 255
    fi
    ensure_master || return 255
    ssh "${SSH_OPTS[@]}" "$SSH_HOST" "$@"
}

# Serialize environment variable assignments for remote execution
remote_env() {
    local v out=""
    for v in "$@"; do out+="$v=$(printf '%q' "${!v}") "; done
    printf '%s' "$out"
}

remote_healthy() {
    rssh "curl -sf -m 5 http://127.0.0.1:$REMOTE_PORT/health >/dev/null" 2>/dev/null
}

EXIT_MARK='[strata-colab-cli] setup.sh exited'
PORT_ERR_RE='already in use|address in use|eaddrinuse'

# Launch or restart Strata on the Colab VM inside tmux.
# Secrets (API_KEY, HF_TOKEN) are piped via stdin rather than passed on the command line.
remote_start() {
    local FORCE_RESTART="${1:-0}"
    {
        printf 'API_KEY=%q\nHF_TOKEN=%q\n' "$API_KEY" "$HF_TOKEN"
        cat "$ROOT/lib/messages.sh" "$ROOT/lib/remote-setup.sh"
    } | rssh "$(remote_env STRATA_REPO REMOTE_DIR DATA_DIR MODEL CONTEXT REMOTE_PORT STRATA_EXTRA_ARGS REMOTE_LOG \
                MODEL_FAMILY MODEL_REPO MODEL_FILES MODEL_REVISION USE_DRIVE DRIVE_DATA_DIR UI_MODE TUNE_ON_START FORCE_RESTART MSG_LANG) bash -s"
}

# Poll the remote VM state in a single SSH call: HEALTHY / PORT_IN_USE / EXITED / NOT_RUNNING / last log line
remote_poll() {
    local q_log
    q_log="$(printf '%q' "$REMOTE_LOG")"
    rssh "if curl -sf -m 5 http://127.0.0.1:$REMOTE_PORT/health >/dev/null 2>&1; then echo HEALTHY;
          elif tail -n 40 $q_log 2>/dev/null | grep -qiE '$PORT_ERR_RE'; then echo PORT_IN_USE;
          elif tail -n 5 $q_log 2>/dev/null | grep -qF '$EXIT_MARK'; then echo EXITED;
          elif ! tmux has-session -t strata 2>/dev/null; then echo NOT_RUNNING;
          else tail -c 400 $q_log 2>/dev/null | tr '\r' '\n' | grep -v '^[[:space:]]*\$' | tail -n 1; fi" \
        2>/dev/null || { stop_master; echo SSH_FAILED; }
}

# Wait for Strata to finish downloading/starting on the Colab VM, automatically retrying on recoverable errors
wait_healthy() {
    local deadline=$((SECONDS + HEALTH_TIMEOUT_MIN * 60)) status why retries=0 py
    py="$(colab_python || true)"
    while true; do
        status="$(remote_poll)"
        case "$status" in
            HEALTHY) return 0 ;;
            SSH_FAILED)
                if ! session_exists; then
                    if [[ -n "$py" ]] && "$py" "$ROOT/lib/colab-helper.py" adopt "$COLAB_SESSION" >/dev/null 2>&1; then
                        warn "$(msg ssh_no_response)"
                    else
                        die "$(msg runtime_stopped "$COLAB_SESSION")"
                    fi
                else
                    printf '    %s\n' "$(msg ssh_no_response)"
                fi
                ;;
            PORT_IN_USE|EXITED|NOT_RUNNING)
                case "$status" in
                    PORT_IN_USE) why="$(msg why_port_in_use "$REMOTE_PORT")" ;;
                    EXITED)      why="$(msg why_setup_exited)" ;;
                    *)           why="$(msg why_not_running)" ;;
                esac
                (( retries < SETUP_RETRIES )) ||
                    die "$(msg retry_exhausted "$why" "$SETUP_RETRIES")"
                retries=$((retries + 1))
                warn "$(msg retry_setup "$why" "$retries" "$SETUP_RETRIES")"
                remote_start 1
                deadline=$((SECONDS + HEALTH_TIMEOUT_MIN * 60))
                ;;
            *) if [[ -n "${status//[[:space:]]/}" ]]; then printf '    %s\n' "${status:0:160}"; fi ;;
        esac
        (( SECONDS < deadline )) || die "$(msg start_timeout "$HEALTH_TIMEOUT_MIN")"
        maybe_run_workload_monitor || true
        sleep "$POLL_SEC"
    done
}

local_healthy() { curl -sf -m 5 "http://127.0.0.1:$LOCAL_PORT/health" >/dev/null 2>&1; }

local_port_in_use() { ss -ltnH "sport = :$LOCAL_PORT" 2>/dev/null | grep -q .; }

wait_ssh() {
    local i err
    for i in 1 2 3 4 5 6; do
        err="$(rssh true 2>&1 >/dev/null)" && return 0
        if grep -q "429" <<<"$err"; then
            warn "$(msg ssh_busy_429 "$i")"
        else
            warn "$(msg ssh_waiting "$i")"
        fi
        sleep 10
    done
    die "$(msg ssh_failed)"
}

# ----- Active-Workload Colab Kernel Telemetry Monitor -----
_WORKLOAD_LOGGED_ACTIVE=0

workload_monitor_running() {
    local pid
    pid="$(cat "$WORKLOAD_PID_FILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

stop_workload_monitor() {
    local pid
    pid="$(cat "$WORKLOAD_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
    fi
    rm -f "$WORKLOAD_PID_FILE"
    _WORKLOAD_LOGGED_ACTIVE=0
}

remote_workload_active() {
    rssh "python3 -" <<'PY' 2>/dev/null
import os, subprocess, sys
markers = (
    "calibrate_config",
    "strata.py\x00tune",
    "strata.py\x00presets\x00recheck",
    "strata.py\x00calibrate",
    "native-tune/tune-",
    "setup.sh\x00",
    "strata-drive-cache.py\x00restore",
    "npm\x00ci",
    "npm\x00run\x00build",
    "hf\x00download",
)
ignored = (
    "colab-workload.py",
    "strata-drive-cache.py\x00backup",
    "strata-drive-cache.py\x00watch-config",
)
for pid in os.listdir("/proc"):
    if not pid.isdigit():
        continue
    try:
        cmd = open(f"/proc/{pid}/cmdline", "rb").read().decode("utf-8", errors="ignore")
    except OSError:
        continue
    if not cmd or any(x in cmd for x in ignored):
        continue
    if any(m in cmd for m in markers):
        sys.exit(0)
try:
    with open("/tmp/strata-drive-sync.status", "r", encoding="utf-8") as f:
        if f.readline().strip().startswith("SYNCING:"):
            sys.exit(0)
except OSError:
    pass
try:
    out = subprocess.check_output(
        ["nvidia-smi", "--query-gpu=utilization.gpu", "--format=csv,noheader,nounits"],
        stderr=subprocess.DEVNULL, text=True, timeout=5,
    )
    for line in out.splitlines():
        line = line.strip()
        if line and int(float(line)) >= 5:
            sys.exit(0)
except Exception:
    pass
sys.exit(1)
PY
}

maybe_run_workload_monitor() {
    [[ "${ACTIVE_WORKLOAD_MONITOR:-1}" == 1 ]] || return 0
    workload_monitor_running && return 0
    if remote_workload_active; then
        if (( _WORKLOAD_LOGGED_ACTIVE == 0 )); then
            log "$(msg workload_monitor_started)"
            _WORKLOAD_LOGGED_ACTIVE=1
        fi
        colab exec -s "$COLAB_SESSION" --timeout 90 -f "$ROOT/lib/colab-workload.py" \
            </dev/null >>"$WORKLOAD_LOG_FILE" 2>&1 &
        echo "$!" > "$WORKLOAD_PID_FILE"
    else
        if (( _WORKLOAD_LOGGED_ACTIVE == 1 )); then
            log "$(msg workload_monitor_idle)"
            _WORKLOAD_LOGGED_ACTIVE=0
        fi
    fi
    return 0
}

# ----- Shared SSH Port-Forwarding Tunnel -----
stop_master() { ctl exit >/dev/null 2>&1 || true; }

FWD_SPEC="127.0.0.1:$LOCAL_PORT:127.0.0.1:$REMOTE_PORT"
KEEPALIVE_PID=""

open_link() {
    rssh true || return 1
    if [[ -z "$KEEPALIVE_PID" ]] || ! kill -0 "$KEEPALIVE_PID" 2>/dev/null; then
        # shellcheck disable=SC2016
        ssh "${SSH_OPTS[@]}" "$SSH_HOST" 'while kill -0 $PPID 2>/dev/null; do sleep 30; done' \
            </dev/null >/dev/null 2>&1 &
        KEEPALIVE_PID=$!
    fi
    ctl forward -L "$FWD_SPEC" >/dev/null 2>&1
}

close_link() {
    if [[ -n "$KEEPALIVE_PID" ]]; then
        kill "$KEEPALIVE_PID" 2>/dev/null || true
        KEEPALIVE_PID=""
    fi
    ctl cancel -L "$FWD_SPEC" >/dev/null 2>&1 || true
}

open_browser() {
    local url="http://localhost:$LOCAL_PORT"
    if command -v cmd.exe >/dev/null 2>&1; then
        (cd /mnt/c 2>/dev/null || true; cmd.exe /c start "" "$url" >/dev/null 2>&1) || true
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url" >/dev/null 2>&1 || true
    fi
}

print_endpoints() {
    local base="http://localhost:$LOCAL_PORT"
    echo
    echo "  $(msg ep_webui "$base")"
    echo "  $(msg ep_openai "$base/v1")"
    echo "  $(msg ep_anthropic "$base/v1/messages")"
    echo "  $(msg ep_apikey "${API_KEY:-$(msg ep_apikey_unset)}")"
    echo
}

stop_tunnel() {
    local pid
    pid="$(cat "$TUNNEL_PID_FILE" 2>/dev/null)" || return 0
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        local i
        for i in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    fi
    rm -f "$TUNNEL_PID_FILE"
}

run_tunnel_foreground() {
    local other
    other="$(cat "$TUNNEL_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$other" && "$other" != "$$" ]] && kill -0 "$other" 2>/dev/null && local_healthy; then
        log "$(msg tunnel_already)"
        [[ "$OPEN_BROWSER" == 1 ]] && open_browser
        print_endpoints
        return 0
    fi
    close_link
    if local_port_in_use; then
        die "$(msg local_port_busy "$LOCAL_PORT")"
    fi

    echo "$$" > "$TUNNEL_PID_FILE"
    trap 'stop_workload_monitor; close_link; rm -f "$TUNNEL_PID_FILE"; echo; warn "$(msg tunnel_closed)"' EXIT
    trap 'exit 130' INT TERM

    open_link || die "$(msg tunnel_failed)"
    local i
    for i in $(seq 1 30); do
        local_healthy && break
        sleep 2
    done
    local_healthy || die "$(msg tunnel_unreachable)"

    log "$(msg ready)"
    [[ "$OPEN_BROWSER" == 1 ]] && open_browser
    print_endpoints
    log "$(msg tunnel_hold)"
    watch_strata
}

# Watchdog loop: monitors tunnel health, reports Google Drive backup progress, and auto-recovers dropped tunnels
watch_strata() {
    local fails=0 drive_done=0 dstat=""
    [[ "$USE_DRIVE" == 1 ]] || drive_done=1
    while true; do
        if (( drive_done == 0 )); then
            dstat="$(rssh "cat /tmp/strata-drive-sync.status 2>/dev/null" 2>/dev/null || true)"
            case "$dstat" in
                SYNCING:*)
                    log "$(msg drive_syncing_progress "${dstat#SYNCING:}")"
                    ;;
                DONE)
                    log "$(msg drive_sync_done "$DRIVE_DATA_DIR")"
                    drive_done=1
                    ;;
                CACHED)
                    drive_done=1
                    ;;
                NO_SPACE:*)
                    local ns="${dstat#NO_SPACE:}"
                    warn "$(msg drive_sync_nospace "${ns%%:*}" "${ns#*:}")"
                    drive_done=1
                    ;;
            esac
        fi
        maybe_run_workload_monitor || true
        sleep "$WATCH_SEC"
        if local_healthy; then
            fails=0
            continue
        fi
        fails=$((fails + 1))
        (( fails >= 2 )) || continue
        fails=0

        session_exists || { warn "$(msg runtime_stopped "$COLAB_SESSION")"; break; }
        if remote_healthy; then
            warn "$(msg tunnel_stuck)"
            open_link || warn "$(msg relink_retry_later)"
            continue
        fi
        warn "$(msg strata_down_recovering)"
        remote_start 0
        wait_healthy
        open_link || warn "$(msg relink_retry_later)"
        log "$(msg recovered)"
    done
}
