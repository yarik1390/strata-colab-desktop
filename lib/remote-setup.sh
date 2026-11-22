#!/usr/bin/env bash
# ==============================================================================
# Remote Colab VM Provisioner (Strata Engine, Google Drive Cache & Desktop UI)
# ==============================================================================
# Executed on the Colab VM via `remote_start()` in lib/common.sh.
# Environment variables received:
#   STRATA_REPO, REMOTE_DIR, DATA_DIR, MODEL, CONTEXT, REMOTE_PORT,
#   STRATA_EXTRA_ARGS, REMOTE_LOG, MODEL_FAMILY, MODEL_REPO, MODEL_FILES,
#   MODEL_REVISION, USE_DRIVE, DRIVE_DATA_DIR, UI_MODE, TUNE_ON_START,
#   FORCE_RESTART (0 = start if not running, 1 = retry setup, 2 = force restart)
#   API_KEY and HF_TOKEN are prepended via stdin so they never appear in argv.
set -euo pipefail

TMUX_SESSION=strata
EXIT_MARK='[strata-colab-cli] setup.sh exited'
PORT_ERR_RE='already in use|address in use|eaddrinuse'
FORCE_RESTART="${FORCE_RESTART:-0}"

rmsg() { echo "[remote] $(msg "$@")"; }

if [[ "$FORCE_RESTART" == 2 ]]; then
    rmsg r_restart
elif curl -sf -m 5 "http://127.0.0.1:$REMOTE_PORT/health" >/dev/null 2>&1; then
    rmsg r_already_running
    exit 0
elif command -v tmux >/dev/null 2>&1 && tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    if [[ "$FORCE_RESTART" == 1 ]]; then
        rmsg r_redo
    elif tail -n 5 "$REMOTE_LOG" 2>/dev/null | grep -qF "$EXIT_MARK"; then
        rmsg r_prev_exited
    elif tail -n 40 "$REMOTE_LOG" 2>/dev/null | grep -qiE "$PORT_ERR_RE"; then
        rmsg r_port_fail_restart "$REMOTE_PORT"
    else
        rmsg r_in_progress
        exit 0
    fi
fi

need_pkg() {
    command -v "$1" >/dev/null 2>&1 && return 0
    rmsg r_installing "$2"
    apt-get -qq update >/dev/null
    apt-get -qq install -y "$2" >/dev/null
}
need_pkg tmux tmux
need_pkg ss iproute2

# ----- Clean Up Previous Strata Processes & Free Target Port -----
under_strata() {
    [[ -n "$1" ]] || return 1
    [[ "$1" == "$REMOTE_DIR" || "$1" == "$REMOTE_DIR"/* || "$1" == "$DATA_DIR" || "$1" == "$DATA_DIR"/* ]]
}
is_strata_pid() {
    local cwd exe
    cwd="$(readlink "/proc/$1/cwd" 2>/dev/null)" || return 1
    exe="$(readlink "/proc/$1/exe" 2>/dev/null)" || true
    under_strata "$cwd" || under_strata "$exe"
}
strata_pids() {
    local d p
    for d in /proc/[0-9]*; do
        p="${d#/proc/}"
        [[ "$p" == "$$" || "$p" == "$PPID" ]] && continue
        is_strata_pid "$p" && echo "$p"
    done
    return 0
}
port_pids() {
    ss -ltnpH "sport = :$REMOTE_PORT" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u
}
kill_and_wait() {
    local p alive i
    kill "$@" 2>/dev/null || true
    for i in $(seq 1 10); do
        alive=""
        for p in "$@"; do kill -0 "$p" 2>/dev/null && alive+="$p "; done
        [[ -z "$alive" ]] && return 0
        sleep 1
    done
    # shellcheck disable=SC2086
    kill -9 $alive 2>/dev/null || true
    sleep 1
}

tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
mapfile -t old < <(strata_pids)
if (( ${#old[@]} > 0 )); then
    rmsg r_stop_old "${old[*]}"
    kill_and_wait "${old[@]}"
fi

mapfile -t holders < <(port_pids)
if (( ${#holders[@]} > 0 )); then
    others=""
    for p in "${holders[@]}"; do
        if is_strata_pid "$p"; then
            kill_and_wait "$p"
        else
            others+="  pid $p: $(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | cut -c1-120)"$'\n'
        fi
    done
    if [[ -n "$others" ]]; then
        rmsg r_port_other "$REMOTE_PORT"
        printf '%s' "$others"
        rmsg r_port_other_hint
        exit 3
    fi
fi

# ----- Clone Strata Repository -----
if [[ ! -d "$REMOTE_DIR/.git" ]]; then
    rmsg r_cloning "$STRATA_REPO"
    git clone --depth 1 "$STRATA_REPO" "$REMOTE_DIR"
fi

# ----- Locate Python 3.10+ with venv & ensurepip -----
ok_py() { "$1" -c 'import sys, venv, ensurepip; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; }
find_py() {
    local c
    for c in $(type -ap python3 python3.12 python3.11 python3.10) \
             /usr/bin/python3 /usr/bin/python3.12 /usr/bin/python3.11 /usr/bin/python3.10; do
        if [[ -x "$c" ]] && ok_py "$c"; then
            echo "$c"
            return 0
        fi
    done
    return 1
}
if ! PY="$(find_py)"; then
    rmsg r_py_install
    apt-get -qq update >/dev/null
    apt-get -qq install -y python3 python3-venv python3-pip >/dev/null
    PY="$(find_py)" || { rmsg r_py_missing; exit 1; }
fi
PY_SHIM_DIR="$(dirname "$REMOTE_DIR")/.strata-python"
mkdir -p "$PY_SHIM_DIR"
ln -sf "$PY" "$PY_SHIM_DIR/python3"
ln -sf "$PY" "$PY_SHIM_DIR/python"
rmsg r_py "$PY" "$("$PY" --version 2>&1)"

# ----- Synchronize Saved Run Config Ports -----
for f in "$REMOTE_DIR"/strata-*.json "$REMOTE_DIR"/terminal/strata-*.json; do
    [[ -f "$f" ]] || continue
    old_ports="$("$PY" - "$f" "$REMOTE_PORT" <<'PYEOF'
import json, sys
path, port = sys.argv[1], int(sys.argv[2])
with open(path, encoding="utf-8") as fh:
    cfg = json.load(fh)
if not isinstance(cfg, dict):
    sys.exit(0)
changed = []
if "port" in cfg and str(cfg["port"]) != str(port):
    changed.append(str(cfg["port"]))
    cfg["port"] = port
args = cfg.get("args")
if isinstance(args, list):
    for i, a in enumerate(args[:-1]):
        if a == "--port" and str(args[i + 1]) != str(port):
            changed.append(str(args[i + 1]))
            args[i + 1] = str(port)
if changed:
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(cfg, fh, indent=2, ensure_ascii=False)
    print(", ".join(sorted(set(changed))))
PYEOF
)"
    [[ -z "$old_ports" ]] || rmsg r_port_fixed "$f" "$old_ports" "$REMOTE_PORT"
done

# ----- Custom Hugging Face GGUF Repository (Optional) -----
GGUF_DIR=""
FETCH_CMD=""
if [[ -n "$MODEL_REPO" ]]; then
    WORK_DIR="$(dirname "$REMOTE_DIR")/.strata-colab"
    HF_VENV="$WORK_DIR/hf-venv"
    HF_TOKEN_FILE="$WORK_DIR/hf_token"
    CUSTOM_DIR="$DATA_DIR/custom/${MODEL_REPO//\//__}"
    PATTERN="${MODEL_FILES:-*${MODEL}*.gguf}"
    mkdir -p "$WORK_DIR" "$CUSTOM_DIR"

    if [[ -n "${HF_TOKEN:-}" ]]; then
        (umask 077 && printf '%s' "$HF_TOKEN" > "$HF_TOKEN_FILE")
    else
        rm -f "$HF_TOKEN_FILE"
    fi
    hf_env=()
    [[ -f "$HF_TOKEN_FILE" ]] && hf_env=(HF_TOKEN_PATH="$HF_TOKEN_FILE")

    if [[ ! -x "$HF_VENV/bin/hf" ]]; then
        rmsg r_hf_install
        "$PY" -m venv "$HF_VENV"
        "$HF_VENV/bin/python" -m pip install -q --disable-pip-version-check "huggingface_hub[hf_xet]"
    fi

    rmsg r_custom_inspect "$MODEL_REPO" "$MODEL"
    set +e
    (export PATH="$PY_SHIM_DIR:$PATH" HF_TOKEN="${HF_TOKEN:-}"; cd "$REMOTE_DIR" && ./setup.sh --inspect "hf:$MODEL_REPO" "$MODEL")
    rc=$?
    set -e
    if (( rc == 2 )); then
        rmsg r_custom_unsupported "$MODEL_REPO" "$MODEL"
        exit 4
    elif (( rc != 0 )); then
        rmsg r_custom_inspect_unknown "$rc"
    fi

    set +e
    plan="$(env "${hf_env[@]}" "$HF_VENV/bin/python" - "$MODEL_REPO" "$MODEL_REVISION" "$PATTERN" "$CUSTOM_DIR" <<'PYEOF'
import fnmatch, os, posixpath, shutil, sys
from huggingface_hub import HfApi
repo, rev, pattern, dest = sys.argv[1], sys.argv[2] or None, sys.argv[3], sys.argv[4]
try:
    info = HfApi().model_info(repo, revision=rev, files_metadata=True)
except Exception as e:
    print(f"error={type(e).__name__}: {e}", file=sys.stderr)
    sys.exit(10)
files = [s for s in info.siblings if fnmatch.fnmatch(s.rfilename, pattern)]
if not files:
    sys.exit(3)
dirs = {posixpath.dirname(s.rfilename) for s in files}
if len(dirs) != 1:
    sys.exit(4)
need = 0
for s in files:
    local = os.path.join(dest, s.rfilename)
    have = os.path.getsize(local) if os.path.exists(local) else 0
    if have != (s.size or 0):
        need += (s.size or 0) - have
free = shutil.disk_usage(dest).free
print(f"files={len(files)}")
print(f"subdir={dirs.pop()}")
print(f"need_bytes={need}")
print(f"need_gb={need / 1e9:.1f}")
print(f"free_gb={free / 1e9:.1f}")
sys.exit(5 if need > free * 0.98 else 0)
PYEOF
)"
    rc=$?
    set -e
    plan_get() { sed -n "s/^$1=//p" <<<"$plan"; }
    case "$rc" in
        0) ;;
        3) rmsg r_custom_nofiles "$MODEL_REPO" "$PATTERN"; exit 4 ;;
        4) rmsg r_custom_multidir "$PATTERN"; exit 4 ;;
        5) rmsg r_custom_disk "$(plan_get need_gb)" "$(plan_get free_gb)"; exit 4 ;;
        *) rmsg r_custom_lookup_failed "$MODEL_REPO"; exit 4 ;;
    esac
    GGUF_DIR="$CUSTOM_DIR"
    subdir="$(plan_get subdir)"
    [[ -n "$subdir" ]] && GGUF_DIR="$CUSTOM_DIR/$subdir"
    if [[ "$(plan_get need_bytes)" == "0" ]]; then
        rmsg r_custom_ready "$MODEL_REPO"
    else
        rmsg r_custom_plan "$MODEL_REPO" "$(plan_get files)" "$CUSTOM_DIR" "$(plan_get need_gb)" "$(plan_get free_gb)"
    fi

    dl=("$HF_VENV/bin/hf" download "$MODEL_REPO" --include "$PATTERN" --local-dir "$CUSTOM_DIR")
    [[ -n "$MODEL_REVISION" ]] && dl+=(--revision "$MODEL_REVISION")
    FETCH_CMD="env $(printf '%q ' "${hf_env[@]}" "${dl[@]}") && "
fi

# ----- Google Drive Persistent Cache & Fast Local SSD Restore -----
USE_DRIVE="${USE_DRIVE:-1}"
DRIVE_DATA_DIR="${DRIVE_DATA_DIR:-/content/drive/MyDrive/Strata-data}"
DRIVE_CACHE_SCRIPT="/tmp/strata-drive-cache.py"
DRIVE_SYNC_STATUS="/tmp/strata-drive-sync.status"

cat > "$DRIVE_CACHE_SCRIPT" <<'PYEOF'
#!/usr/bin/env python3
import os
import shutil
import sys
import time
import urllib.request

STATUS_FILE = "/tmp/strata-drive-sync.status"
SHARED_KEYWORDS = ("mmproj", "mtp", "ple-fp8", "token-embd", "dense.gguf", "dflash2", ".json")


def write_status(text: str) -> None:
    try:
        with open(STATUS_FILE + ".tmp", "w", encoding="utf-8") as f:
            f.write(text + "\n")
        os.replace(STATUS_FILE + ".tmp", STATUS_FILE)
    except OSError:
        pass


def matches_model(rel_path: str, model: str) -> bool:
    low = rel_path.lower().replace("\\", "/")
    if low.endswith(".part") or low.endswith(".tmp") or low.endswith(".incomplete") or low.endswith(".lock"):
        return False
    if low.startswith("conversation-spill/"):
        return False
    base = low[:-5] if low.endswith(".done") else low
    if model and model.lower() in base:
        return True
    return any(k in base for k in SHARED_KEYWORDS)


def copy_with_progress(src: str, dst: str, label: str, update_status: bool = False) -> None:
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    total = os.path.getsize(src)
    tmp = dst + ".tmp"
    copied = 0
    last_print = 0.0
    with open(src, "rb") as fsrc, open(tmp, "wb") as fdst:
        while True:
            buf = fsrc.read(16 * 1024 * 1024)
            if not buf:
                break
            fdst.write(buf)
            copied += len(buf)
            now = time.time()
            if now - last_print >= 2.5 and total > 0:
                last_print = now
                pct = int(copied * 100 // total)
                msg = f"{os.path.basename(dst)}: {copied / 1e9:.2f} / {total / 1e9:.2f} GB ({pct}%)"
                print(f"  [{label}] {msg}", flush=True)
                if update_status:
                    write_status(f"SYNCING:{msg}")
        fdst.flush()
        os.fsync(fdst.fileno())
    os.replace(tmp, dst)
    try:
        shutil.copystat(src, dst)
    except OSError:
        pass


def cmd_restore(drive_dir: str, data_dir: str, model: str) -> int:
    if not os.path.isdir(drive_dir):
        return 0
    candidates = []
    for root, _, files in os.walk(drive_dir):
        for fn in sorted(files):
            if fn.endswith(".done") or fn.endswith(".tmp") or fn.endswith(".part"):
                continue
            full = os.path.join(root, fn)
            rel = os.path.relpath(full, drive_dir)
            if matches_model(rel, model):
                candidates.append(rel)

    if not candidates:
        print(f"[remote] No cached files for {model} in Google Drive ({drive_dir}) yet.", flush=True)
        return 0

    restored_files = 0
    restored_bytes = 0
    for rel in candidates:
        src = os.path.join(drive_dir, rel)
        dst = os.path.join(data_dir, rel)
        src_done = src + ".done"
        dst_done = dst + ".done"
        size = os.path.getsize(src)
        if not (os.path.isfile(dst) and os.path.getsize(dst) == size):
            print(f"[remote] Restoring from Google Drive: {rel} ({size / 1e9:.2f} GB)", flush=True)
            copy_with_progress(src, dst, "Drive -> SSD", update_status=False)
            restored_files += 1
            restored_bytes += size
        if os.path.isfile(src_done) and not os.path.isfile(dst_done):
            os.makedirs(os.path.dirname(dst_done), exist_ok=True)
            shutil.copy2(src_done, dst_done)

    if restored_files > 0:
        print(
            f"[remote] Restored {restored_files} file(s) ({restored_bytes / 1e9:.2f} GB) from Google Drive.",
            flush=True,
        )
    else:
        print(f"[remote] Cached files for {model} are already present on local SSD.", flush=True)
    return 0


def is_healthy(port: str) -> bool:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=3) as r:
            return r.status == 200
    except Exception:
        return False


def is_calibrating() -> bool:
    try:
        for pid in os.listdir("/proc"):
            if not pid.isdigit():
                continue
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                cmd = f.read().decode("utf-8", errors="ignore")
            if "calibrate_config" in cmd or "strata.py\x00tune" in cmd:
                return True
    except Exception:
        pass
    return False


def cmd_backup_loop(data_dir: str, drive_dir: str, port: str) -> int:
    drive_parent = os.path.dirname(drive_dir.rstrip("/"))
    if not os.path.isdir(drive_parent):
        return 0
    os.makedirs(drive_dir, exist_ok=True)
    write_status("IDLE")
    synced_any = False

    while True:
        time.sleep(12)
        if not os.path.isdir(data_dir) or is_calibrating():
            continue
        healthy = is_healthy(port)
        pending = []
        for root, _, files in os.walk(data_dir):
            rel_root = os.path.relpath(root, data_dir).replace("\\", "/")
            if rel_root.startswith("conversation-spill"):
                continue
            for fn in sorted(files):
                if fn.endswith(".part") or fn.endswith(".tmp") or fn.endswith(".lock"):
                    continue
                full = os.path.join(root, fn)
                if os.path.exists(full + ".part") or os.path.exists(full + ".tmp"):
                    continue
                if fn.endswith(".gguf"):
                    has_done = os.path.isfile(full + ".done")
                    is_custom = "/custom/" in full.replace("\\", "/")
                    if not (has_done or (is_custom and healthy)):
                        continue
                elif not (rel_root.startswith("packs") or rel_root.startswith("dflash2") or fn.endswith(".done")):
                    continue
                rel = os.path.relpath(full, data_dir)
                dst = os.path.join(drive_dir, rel)
                size = os.path.getsize(full)
                if not (os.path.isfile(dst) and os.path.getsize(dst) == size):
                    pending.append((rel, full, dst, size))

        for rel, full, dst, size in pending:
            if is_calibrating():
                break
            free_bytes = shutil.disk_usage(drive_dir).free
            if size + (512 * 1024 * 1024) > free_bytes:
                write_status(f"NO_SPACE:{size / 1e9:.1f}:{free_bytes / 1e9:.1f}")
                return 0
            try:
                copy_with_progress(full, dst, "SSD -> Drive", update_status=True)
                if os.path.isfile(full + ".done"):
                    shutil.copy2(full + ".done", dst + ".done")
                synced_any = True
            except Exception as e:
                write_status(f"ERROR:{e}")

        if healthy and not pending and not is_calibrating():
            write_status("DONE" if synced_any else "CACHED")
            return 0


if __name__ == "__main__":
    if len(sys.argv) >= 5 and sys.argv[1] == "restore":
        sys.exit(cmd_restore(sys.argv[2], sys.argv[3], sys.argv[4]))
    elif len(sys.argv) >= 5 and sys.argv[1] == "backup":
        sys.exit(cmd_backup_loop(sys.argv[2], sys.argv[3], sys.argv[4]))
    sys.exit(1)
PYEOF
chmod +x "$DRIVE_CACHE_SCRIPT"

pkill -f "[s]trata-drive-cache.py backup" 2>/dev/null || true
rm -f "$DRIVE_SYNC_STATUS"

RESTORE_CMD=""
if [[ "$USE_DRIVE" == 1 ]]; then
    RESTORE_CMD="$PY $DRIVE_CACHE_SCRIPT restore $(printf '%q ' "$DRIVE_DATA_DIR" "$DATA_DIR" "$MODEL") && "
fi

UI_MODE="${UI_MODE:-desktop}"
TUNE_ON_START="${TUNE_ON_START:-0}"
ENGINE_PORT=$((REMOTE_PORT + 1))

args=(--model "$MODEL" --context "$CONTEXT" --port "$([[ "$UI_MODE" == "desktop" ]] && echo "$ENGINE_PORT" || echo "$REMOTE_PORT")"
      --data-dir "$DATA_DIR" --no-browser --yes)
[[ "$UI_MODE" == "desktop" ]] && args+=(--no-start)
[[ -n "$MODEL_FAMILY" ]] && args+=(--family "$MODEL_FAMILY")
[[ -n "$GGUF_DIR" ]] && args+=(--gguf-dir "$GGUF_DIR")
[[ -n "$API_KEY" ]] && args+=(--api-key "$API_KEY")
# shellcheck disable=SC2086,SC2206
[[ -n "$STRATA_EXTRA_ARGS" ]] && args+=($STRATA_EXTRA_ARGS)

[[ -f "$REMOTE_LOG" ]] && mv -f "$REMOTE_LOG" "$REMOTE_LOG.prev"

RUN_WRAPPER="/tmp/strata-tmux-runner.sh"
cat > "$RUN_WRAPPER" <<EOF
#!/usr/bin/env bash
set -uo pipefail
export PATH=$(printf '%q' "$PY_SHIM_DIR"):/content/.strata-node/bin:\$PATH

if [[ $(printf '%q' "$USE_DRIVE") == 1 && -d $(printf '%q' "$(dirname "$DRIVE_DATA_DIR")") ]]; then
    $(printf '%q' "$PY") $(printf '%q' "$DRIVE_CACHE_SCRIPT") backup $(printf '%q ' "$DATA_DIR" "$DRIVE_DATA_DIR" "$REMOTE_PORT") >/content/strata-drive-sync.log 2>&1 &
fi

cd $(printf '%q' "$REMOTE_DIR")
{
    ${RESTORE_CMD}${FETCH_CMD}./setup.sh $(printf '%q ' "${args[@]}")

    if [[ $(printf '%q' "$UI_MODE") == "desktop" ]]; then
        NODE_DIR=/content/.strata-node
        if [[ ! -x "\$NODE_DIR/bin/node" ]]; then
            echo "[desktop] Installing Node v24.12.0 for Strata Desktop..."
            mkdir -p "\$NODE_DIR"
            curl -fsSL https://nodejs.org/dist/v24.12.0/node-v24.12.0-linux-x64.tar.gz | tar xz -C "\$NODE_DIR" --strip-components=1
        fi
        export PATH="\$NODE_DIR/bin:\$PATH"
        cd $(printf '%q' "$REMOTE_DIR/app/host")
        if [[ ! -f dist/index.html ]]; then
            echo "[desktop] Building Strata Desktop UI..."
            npm ci --no-audit --no-fund
            npm run build
        fi
        sed -i "s|if (path === '/api/health')|if (path === '/api/health' \|\| path === '/health')|g" server/index.mjs

        $(printf '%q' "$PY") - <<'PYCFG'
import glob, json
for p in glob.glob('/content/Strata/strata-*.json') + glob.glob('/content/Strata/terminal/strata-*.json'):
    try:
        with open(p, 'r', encoding='utf-8') as f:
            cfg = json.load(f)
        for k in ('args', 'args_written'):
            arr = cfg.get(k)
            if isinstance(arr, list):
                for i in range(len(arr) - 1):
                    if arr[i] == '--max-context':
                        arr[i + 1] = '$CONTEXT'
        cfg['port'] = int('$ENGINE_PORT')
        cfg['ui_context_chosen'] = True
        with open(p, 'w', encoding='utf-8') as f:
            json.dump(cfg, f, indent=2)
    except Exception:
        pass
PYCFG

        export STRATA_REAL_ENGINE=1
        export STRATA_PORT=$(printf '%q' "$REMOTE_PORT")
        export STRATA_BIND=127.0.0.1
        export STRATA_NATIVE_REPO=$(printf '%q' "$REMOTE_DIR")
        export STRATA_PYTHON=$(printf '%q' "$REMOTE_DIR/terminal/.venv/bin/python")
        export STRATA_WORKSPACE=/content/Workspace
        mkdir -p /content/Workspace

        (
            for _ in {1..30}; do
                curl -sf "http://127.0.0.1:$REMOTE_PORT/api/health" >/dev/null 2>&1 && break
                sleep 1
            done
            curl -sf "http://127.0.0.1:$REMOTE_PORT/api/native?refresh=1" >/dev/null 2>&1 || true
            sleep 2
            MODEL_ID=\$(echo $(printf '%q' "$MODEL") | tr '[:upper:]' '[:lower:]')
            if [[ -n $(printf '%q' "$MODEL_FAMILY") && $(printf '%q' "$MODEL_FAMILY") != "qwen" ]]; then
                MODEL_ID="\$(echo $(printf '%q' "$MODEL_FAMILY") | tr '[:upper:]' '[:lower:]')-\$MODEL_ID"
            fi
            if [[ $(printf '%q' "$TUNE_ON_START") == 1 ]]; then
                curl -sf -X POST "http://127.0.0.1:$REMOTE_PORT/api/native/operations" -H 'Content-Type: application/json' \
                    -d "{\"kind\":\"tune\",\"args\":{\"model\":\"\$MODEL_ID\",\"profile\":\"performance\"}}" >/dev/null 2>&1 || true
            else
                curl -sf -X POST "http://127.0.0.1:$REMOTE_PORT/api/native/operations" -H 'Content-Type: application/json' \
                    -d "{\"kind\":\"load\",\"args\":{\"model\":\"\$MODEL_ID\"}}" >/dev/null 2>&1 || true
            fi
        ) &

        node server/index.mjs --dist dist
    fi
} 2>&1 | tee -a $(printf '%q' "$REMOTE_LOG")
echo $(printf '%q' "$EXIT_MARK") | tee -a $(printf '%q' "$REMOTE_LOG")
sleep infinity
EOF
chmod +x "$RUN_WRAPPER"

tmux new-session -d -s "$TMUX_SESSION" "$RUN_WRAPPER"
rmsg r_started "$UI_MODE" "$MODEL" "$CONTEXT" "$REMOTE_PORT"
