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
WORKLOAD_LOCK_FILE="$STATE_DIR/workload-monitor.lock"
mkdir -p "$STATE_DIR"

declare -A _CALLER_ENV=()
for _k in COLAB_SESSION GPU ASK_GPU HIGH_MEM ON_GPU_MISMATCH \
          MODEL ASK_MODEL MODEL_FAMILY MODEL_REPO MODEL_FILES MODEL_REVISION \
          CONTEXT TUNE_ON_START HF_XET_HIGH_PERFORMANCE STRATA_UV \
          STRATA_KV_CACHE STRATA_VISION STRATA_DRAFTER STRATA_EXTRA_ARGS \
          REMOTE_PORT USE_DRIVE DRIVE_MODEL_CACHE LOCAL_PORT \
          ACTIVE_WORKLOAD_MONITOR AUTO_STOP_IDLE_MIN UI_MODE OPEN_BROWSER STRATA_UI_HOST; do
    if [[ -v "$_k" ]]; then
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
STRATA_EXTRA_ARGS="${STRATA_EXTRA_ARGS:-}"
HF_XET_HIGH_PERFORMANCE="${HF_XET_HIGH_PERFORMANCE:-1}"
STRATA_UV="${STRATA_UV:-1}"
STRATA_KV_CACHE="${STRATA_KV_CACHE:-}"
STRATA_VISION="${STRATA_VISION:-}"
STRATA_DRAFTER="${STRATA_DRAFTER:-}"
USE_DRIVE="${USE_DRIVE:-1}"
DRIVE_MODEL_CACHE="${DRIVE_MODEL_CACHE:-0}"
DRIVE_MOUNT="${DRIVE_MOUNT:-/content/drive}"
DRIVE_DATA_DIR="${DRIVE_DATA_DIR:-/content/drive/MyDrive/Strata-data}"
UI_MODE="${UI_MODE:-desktop}"
TUNE_ON_START="${TUNE_ON_START:-0}"
ACTIVE_WORKLOAD_MONITOR="${ACTIVE_WORKLOAD_MONITOR:-1}"
AUTO_STOP_IDLE_MIN="${AUTO_STOP_IDLE_MIN:-0}"
ON_GPU_MISMATCH="${ON_GPU_MISMATCH:-ask}"
STRATA_UI_HOST="${STRATA_UI_HOST:-0}"

export COLAB_SESSION STRATA_UI_HOST
command -v colab >/dev/null 2>&1 || export PATH="$HOME/.local/bin:$PATH"
if [[ -z "${BROWSER:-}" && -x "$ROOT/lib/wsl-open-url.sh" ]] && command -v powershell.exe >/dev/null 2>&1; then
    export BROWSER="$ROOT/lib/wsl-open-url.sh"
fi

SSH_HOST="${SSH_HOST:-colab-strata}"
SSH_OPTS=(-F "$ROOT/ssh_config")
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[33m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '\033[31m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

emit_ui_state() {
    [[ "${STRATA_UI_HOST:-0}" == 1 ]] && printf '[STRATA_STATE:%s]\n' "$1" || true
}

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

adopt_existing_session() {
    local py
    if py="$(colab_python 2>/dev/null)"; then
        "$py" "$ROOT/lib/colab-helper.py" adopt "$COLAB_SESSION" >/dev/null 2>&1 || true
    fi
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
# Redirect stdin from /dev/null and close FD 9 so ssh -f never inherits the flock.
ensure_master() {
    ctl check >/dev/null 2>&1 && return 0
    (
        flock -w 30 9 || exit 1
        ctl check >/dev/null 2>&1 && exit 0
        setsid -w ssh "${SSH_OPTS[@]}" -o ControlMaster=yes -N -f "$SSH_HOST" </dev/null 9>&-
    ) 9>"$HOME/.ssh/colab-cm-$COLAB_SESSION.lock"
}

# Execute a command over multiplexed SSH when runtime existence has already been verified
rssh_direct() {
    ensure_master || return 255
    ssh "${SSH_OPTS[@]}" "$SSH_HOST" "$@"
}

# Execute a command on the Colab VM over the multiplexed SSH connection
rssh() {
    if ! session_exists; then
        warn "$(msg no_runtime_skip_ssh "$COLAB_SESSION")"
        return 255
    fi
    rssh_direct "$@"
}

# Serialize environment variable assignments for remote execution
remote_env() {
    local v out=""
    for v in "$@"; do out+="$v=$(printf '%q' "${!v}") "; done
    printf '%s' "$out"
}

remote_healthy() {
    rssh "curl -sf -m 5 http://127.0.0.1:$REMOTE_PORT/health >/dev/null 2>&1 || curl -sf -m 5 http://127.0.0.1:$REMOTE_PORT/api/health >/dev/null 2>&1" 2>/dev/null
}

EXIT_MARK='[strata-colab-cli] setup.sh exited'
PORT_ERR_RE='already in use|address in use|eaddrinuse'

VM_VRAM_GB=0
VM_RAM_GB=0
VM_GPU_NAME=""

# Query live VRAM, system RAM, and GPU name on the active Colab VM
probe_vm_memory_gb() {
    local out vram_mib ram_mib gname
    out="$(rssh "nvidia-smi --query-gpu=memory.total,name --format=csv,noheader,nounits 2>/dev/null | head -n1; free -m | awk '/^Mem:/ {print \$2}'" 2>/dev/null || true)"
    local line1 line2
    line1="$(sed -n '1p' <<<"$out")"
    line2="$(sed -n '2p' <<<"$out")"
    vram_mib="$(cut -d',' -f1 <<<"$line1" | tr -dc '0-9')"
    gname="$(cut -d',' -f2- <<<"$line1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    ram_mib="$(tr -dc '0-9' <<<"$line2")"
    vram_mib="${vram_mib:-0}"
    ram_mib="${ram_mib:-0}"
    VM_VRAM_GB=$(( (vram_mib + 512) / 1024 ))
    VM_RAM_GB=$(( (ram_mib + 512) / 1024 ))
    VM_GPU_NAME="${gname:-}"
}

# Return default menu slot (6=nvfp4/NVFP4, 5=IQ3_S, 2=IQ2_XS, 1=qwen36/UD-Q4_K_XL) for the VM
recommended_model_slot() {
    local gpu_hint="${1:-${GPU:-}}"
    local blackwell_re='RTX PRO 6000|BLACKWELL|B200|B100'
    if (( VM_VRAM_GB >= 90 )) && [[ "${VM_GPU_NAME^^}" =~ $blackwell_re ]]; then
        echo 6
    elif (( VM_VRAM_GB >= 40 && VM_RAM_GB >= 80 )); then
        echo 5
    elif (( VM_VRAM_GB >= 22 && VM_RAM_GB >= 48 )); then
        echo 2
    elif (( VM_VRAM_GB > 0 )); then
        echo 1
    else
        case "${gpu_hint^^}" in
            G4)        echo 6 ;;
            A100|H100) echo 5 ;;
            L4)        echo 2 ;;
            *)         echo 1 ;;
        esac
    fi
}

# Resolve MODEL=AUTO using the live VM's VRAM and RAM (or GPU hint)
resolve_auto_model() {
    [[ -z "$MODEL_REPO" && "${MODEL^^}" == "AUTO" ]] || return 0
    probe_vm_memory_gb
    local slot
    slot="$(recommended_model_slot "${1:-${GPU:-}}")"
    case "$slot" in
        6) MODEL_FAMILY="nvfp4";  MODEL="NVFP4" ;;
        5) MODEL_FAMILY="";       MODEL="IQ3_S" ;;
        2) MODEL_FAMILY="";       MODEL="IQ2_XS" ;;
        *) MODEL_FAMILY="qwen36"; MODEL="UD-Q4_K_XL" ;;
    esac
    local gpu_label="${VM_GPU_NAME:-${GPU:-Colab GPU}}"
    log "$(msg model_auto_selected "$MODEL" "${MODEL_FAMILY:-qwen3.8-flash}" "$gpu_label" "${VM_VRAM_GB:-0}" "${VM_RAM_GB:-0}")"
}

# Detect the active Strata model/family running on the VM via HTTP API first,
# then /proc cmdline, falling back to resolve_auto_model.
detect_active_remote_model() {
    [[ "${MODEL^^}" == "AUTO" ]] || return 0
    local detected=""
    detected="$(rssh "STRATA_REMOTE_PORT=$(printf '%q' "$REMOTE_PORT") python3 -" <<'PY' 2>/dev/null || true
import json, os, urllib.request

KNOWN_FAMILIES = ("qwen36", "coder", "nvfp4", "unsloth", "swift", "gyro", "qwen")

def split_model_id(raw_id: str) -> tuple[str, str]:
    raw_id = (raw_id or "").strip()
    if not raw_id or raw_id.upper() == "AUTO":
        return "", ""
    lower = raw_id.lower()
    for fam in KNOWN_FAMILIES:
        prefix = fam + "-"
        if lower.startswith(prefix) and len(raw_id) > len(prefix):
            return raw_id[len(prefix):], fam
    return raw_id, ""

def fetch_json(url: str):
    try:
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=3) as resp:
            if 200 <= resp.status < 300:
                return json.loads(resp.read().decode("utf-8", errors="ignore"))
    except Exception:
        return None
    return None

def extract_from_native(obj) -> str:
    if not isinstance(obj, dict):
        return ""
    for key in ("activeModel", "active_model", "loadedModel", "loaded_model", "currentModel", "selectedModel", "model"):
        val = obj.get(key)
        if isinstance(val, str) and val.strip():
            return val.strip()
        if isinstance(val, dict):
            mid = val.get("id") or val.get("model") or val.get("name")
            if isinstance(mid, str) and mid.strip():
                return mid.strip()
    for container in ("engine", "runtime", "status", "server", "state", "native"):
        sub = obj.get(container)
        if isinstance(sub, dict):
            found = extract_from_native(sub)
            if found:
                return found
    models = obj.get("models")
    if isinstance(models, list):
        for item in models:
            if isinstance(item, dict) and (item.get("active") or item.get("loaded") or item.get("running")):
                mid = item.get("id") or item.get("model") or item.get("name")
                if isinstance(mid, str) and mid.strip():
                    return mid.strip()
    return ""

port = os.environ.get("STRATA_REMOTE_PORT", "8089")

# 1. Try OpenAI-compatible /v1/models on REMOTE_PORT
v1 = fetch_json(f"http://127.0.0.1:{port}/v1/models")
if isinstance(v1, dict) and isinstance(v1.get("data"), list):
    for item in v1["data"]:
        if isinstance(item, dict) and isinstance(item.get("id"), str) and item["id"].strip():
            m, f = split_model_id(item["id"])
            if m:
                print(f"{m}\t{f}")
                raise SystemExit(0)

# 2. Try Strata Desktop /api/native on REMOTE_PORT
native = fetch_json(f"http://127.0.0.1:{port}/api/native")
mid = extract_from_native(native)
if mid:
    m, f = split_model_id(mid)
    if m:
        print(f"{m}\t{f}")
        raise SystemExit(0)

# 3. Fallback: scan /proc for strata.py / setup.sh CLI flags
for pid in os.listdir("/proc"):
    if not pid.isdigit():
        continue
    try:
        args = open(f"/proc/{pid}/cmdline", "rb").read().decode("utf-8", errors="ignore").split("\x00")
    except OSError:
        continue
    if not any("strata.py" in a or "setup.sh" in a for a in args):
        continue
    model = ""
    family = ""
    for i, a in enumerate(args):
        if a == "--model" and i + 1 < len(args):
            model = args[i + 1]
        elif a == "--family" and i + 1 < len(args):
            family = args[i + 1]
    if model and model.upper() != "AUTO":
        print(f"{model}\t{family}")
        break
PY
)"
    if [[ -n "$detected" ]]; then
        IFS=$'\t' read -r MODEL MODEL_FAMILY <<<"$detected"
    else
        resolve_auto_model "${GPU:-}"
    fi
}

# Launch or restart Strata on the Colab VM inside tmux.
# Secrets (API_KEY, HF_TOKEN) are piped via stdin rather than passed on the command line.
remote_start() {
    local FORCE_RESTART="${1:-0}"
    resolve_auto_model "${GPU:-}"
    {
        printf 'API_KEY=%q\nHF_TOKEN=%q\n' "$API_KEY" "$HF_TOKEN"
        cat "$ROOT/lib/messages.sh" "$ROOT/lib/remote-setup.sh"
    } | rssh "$(remote_env STRATA_REPO REMOTE_DIR DATA_DIR MODEL CONTEXT REMOTE_PORT STRATA_EXTRA_ARGS REMOTE_LOG \
                MODEL_FAMILY MODEL_REPO MODEL_FILES MODEL_REVISION USE_DRIVE DRIVE_MODEL_CACHE DRIVE_DATA_DIR UI_MODE TUNE_ON_START FORCE_RESTART MSG_LANG \
                HF_XET_HIGH_PERFORMANCE STRATA_UV STRATA_KV_CACHE STRATA_VISION STRATA_DRAFTER) bash -s"
}

# Poll the remote VM state in a single SSH call: HEALTHY / PORT_IN_USE / EXITED / NOT_RUNNING / last log line
remote_poll() {
    local q_log
    q_log="$(printf '%q' "$REMOTE_LOG")"
    rssh "if curl -sf -m 5 http://127.0.0.1:$REMOTE_PORT/health >/dev/null 2>&1 || curl -sf -m 5 http://127.0.0.1:$REMOTE_PORT/api/health >/dev/null 2>&1; then echo HEALTHY;
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

local_healthy() {
    curl -sf -m 5 "http://127.0.0.1:$LOCAL_PORT/health" >/dev/null 2>&1 || \
    curl -sf -m 5 "http://127.0.0.1:$LOCAL_PORT/api/health" >/dev/null 2>&1
}

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
_WORKLOAD_LOG_RESET=0
_LAST_WORKLOAD_ACTIVE=0

reset_workload_log() {
    (( _WORKLOAD_LOG_RESET == 0 )) || return 0
    : > "$WORKLOAD_LOG_FILE"
    _WORKLOAD_LOG_RESET=1
}

workload_lock_held() {
    [[ -f "$WORKLOAD_LOCK_FILE" ]] || return 1
    ! ( flock -n 9 ) 9>>"$WORKLOAD_LOCK_FILE" 2>/dev/null
}

workload_monitor_running() {
    local pid
    pid="$(cat "$WORKLOAD_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    workload_lock_held
}

stop_workload_monitor() {
    local pid i
    pid="$(cat "$WORKLOAD_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        for i in 1 2 3 4 5; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 1
        done
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
    _LAST_WORKLOAD_ACTIVE=0
    [[ "${ACTIVE_WORKLOAD_MONITOR:-1}" == 1 ]] || return 0
    if workload_monitor_running; then
        _LAST_WORKLOAD_ACTIVE=1
        return 0
    fi
    if remote_workload_active; then
        _LAST_WORKLOAD_ACTIVE=1
        reset_workload_log
        if (( _WORKLOAD_LOGGED_ACTIVE == 0 )); then
            log "$(msg workload_monitor_started)"
            _WORKLOAD_LOGGED_ACTIVE=1
        fi
        (
            flock -n 9 || exit 0
            exec colab exec -s "$COLAB_SESSION" --timeout 90 \
                --env "DRIVE_DATA_DIR=$DRIVE_DATA_DIR" \
                --env "REMOTE_DIR=$REMOTE_DIR" \
                -f "$ROOT/lib/colab-workload.py" </dev/null >>"$WORKLOAD_LOG_FILE" 2>&1
        ) 9>>"$WORKLOAD_LOCK_FILE" &
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
        emit_ui_state "tunnel_ready"
        [[ "$OPEN_BROWSER" == 1 ]] && open_browser
        print_endpoints
        return 0
    fi
    close_link
    if local_port_in_use; then
        die "$(msg local_port_busy "$LOCAL_PORT")"
    fi

    reset_workload_log
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

    emit_ui_state "tunnel_ready"
    log "$(msg ready)"
    [[ "$OPEN_BROWSER" == 1 ]] && open_browser
    print_endpoints
    log "$(msg tunnel_hold)"
    watch_strata
}

# Watchdog loop: monitors tunnel health, reports Google Drive backup progress,
# optionally auto-stops idle VMs, and auto-recovers dropped tunnels.
watch_strata() {
    local fails=0 drive_done=0 dstat=""
    local idle_secs=0 idle_limit_secs=0 last_warn_min=0 idle_min=0 is_busy=0
    [[ "$USE_DRIVE" == 1 && "$DRIVE_MODEL_CACHE" == 1 ]] || drive_done=1
    if [[ "${AUTO_STOP_IDLE_MIN:-0}" =~ ^[0-9]+$ ]] && (( AUTO_STOP_IDLE_MIN > 0 )); then
        idle_limit_secs=$(( AUTO_STOP_IDLE_MIN * 60 ))
    fi

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

        if (( idle_limit_secs > 0 )); then
            is_busy=0
            if (( drive_done == 0 || _LAST_WORKLOAD_ACTIVE == 1 )); then
                is_busy=1
            elif [[ "${ACTIVE_WORKLOAD_MONITOR:-1}" != 1 ]] && remote_workload_active; then
                is_busy=1
            fi
            if (( is_busy == 1 )); then
                idle_secs=0
                last_warn_min=0
            else
                idle_secs=$(( idle_secs + WATCH_SEC ))
                idle_min=$(( idle_secs / 60 ))
                if (( idle_secs >= idle_limit_secs )); then
                    warn "$(msg auto_stop_idle_triggered "$AUTO_STOP_IDLE_MIN")"
                    stop_workload_monitor
                    close_link
                    rm -f "$TUNNEL_PID_FILE"
                    trap - EXIT
                    exec bash "$ROOT/down.sh"
                elif (( idle_min > last_warn_min )) && { (( idle_min >= AUTO_STOP_IDLE_MIN - 5 )) || (( idle_min % 5 == 0 )); }; then
                    log "$(msg auto_stop_idle_warning "$idle_min" "$AUTO_STOP_IDLE_MIN" "$AUTO_STOP_IDLE_MIN")"
                    last_warn_min=$idle_min
                fi
            fi
        fi

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
            close_link
            if ! open_link; then
                stop_master
                open_link || warn "$(msg relink_retry_later)"
            fi
            continue
        fi
        warn "$(msg strata_down_recovering)"
        close_link
        remote_start 0
        wait_healthy
        if ! open_link; then
            stop_master
            open_link || warn "$(msg relink_retry_later)"
        fi
        log "$(msg recovered)"
    done
}
