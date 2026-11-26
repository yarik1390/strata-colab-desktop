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
DRIVE_MODEL_CACHE="${DRIVE_MODEL_CACHE:-0}"
DRIVE_DATA_DIR="${DRIVE_DATA_DIR:-/content/drive/MyDrive/Strata-data}"
DRIVE_CACHE_SCRIPT="/tmp/strata-drive-cache.py"
DRIVE_SYNC_STATUS="/tmp/strata-drive-sync.status"
DRIVE_CONFIG_STATUS="/tmp/strata-config-sync.status"

cat > "$DRIVE_CACHE_SCRIPT" <<'PYEOF'
#!/usr/bin/env python3
import concurrent.futures
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.request

STATUS_FILE = "/tmp/strata-drive-sync.status"
CONFIG_STATUS_FILE = "/tmp/strata-config-sync.status"
PRESET_DIR = os.path.expanduser("~/.config/strata/presets")
PROFILE_DIR = os.path.expanduser("~/.config/strata/profiles")
DESKTOP_STATE_FILE = os.path.expanduser("~/.strata/data/state.json")
SKIP_CONFIG_NAMES = {"last-failed-engine.log"}
SKIP_SUFFIXES = (".tmp", ".part", ".incomplete", ".lock")
SHARED_KEYWORDS = ("mmproj", "mtp", "ple-fp8", "token-embd", "dense.gguf", "dflash2", ".json")
CALIBRATE_MARKERS = (
    "calibrate_config",
    "strata.py\x00tune",
    "strata.py\x00presets\x00recheck",
    "strata.py\x00calibrate",
    "native-tune/tune-",
)
SAFE_PERSISTENT_KEYS = (
    "ui_resource_profile",
    "vram_reserve_mib",
    "ui_reserve_applied",
    "ui_resource_baseline",
    "ui_vision_enabled",
    "ui_vision_device",
    "ui_vision_chosen",
    "env",
    "sampling",
    "parallel",
    "layer_split",
    "user_args",
)


def write_file_atomic(path: str, data: bytes, mode: int | None = None) -> None:
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, mode=0o700 if mode is not None else 0o755, exist_ok=True)
        if mode is not None:
            try:
                os.chmod(parent, 0o700)
            except OSError:
                pass
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
    if mode is not None:
        try:
            os.chmod(path, mode)
        except OSError:
            pass


def _write_status_file(path: str, text: str) -> None:
    try:
        write_file_atomic(path, (text + "\n").encode("utf-8"))
    except OSError:
        pass


def write_status(text: str) -> None:
    _write_status_file(STATUS_FILE, text)


def write_config_status(text: str) -> None:
    _write_status_file(CONFIG_STATUS_FILE, text)


def detect_gpu_slug() -> str:
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
        )
        for line in out.splitlines():
            line = line.strip().lower()
            if line:
                slug = re.sub(r"[^a-z0-9]+", "-", line).strip("-")
                if slug:
                    return slug
    except Exception:
        pass
    return "default"


def matches_model(rel_path: str, model: str) -> bool:
    low = rel_path.lower().replace("\\", "/")
    if low.endswith(".part") or low.endswith(".tmp") or low.endswith(".incomplete") or low.endswith(".lock"):
        return False
    if low.startswith("conversation-spill/") or low.startswith("strata-config/"):
        return False
    base = low[:-5] if low.endswith(".done") else low
    if model and model.lower() in base:
        return True
    return any(k in base for k in SHARED_KEYWORDS)


def copy_with_progress(
    src: str, dst: str, label: str, update_status: bool = False, parallel_read: bool = False
) -> None:
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    total = os.path.getsize(src)
    tmp = dst + ".tmp"
    copied = 0
    last_print = 0.0
    start_t = time.time()
    lock = threading.Lock()

    def report(copied_bytes: int) -> None:
        nonlocal last_print
        now = time.time()
        if now - last_print >= 2.5 and total > 0:
            last_print = now
            elapsed = max(0.001, now - start_t)
            rate_mb = copied_bytes / 1e6 / elapsed
            pct = int(copied_bytes * 100 // total)
            msg = f"{os.path.basename(dst)}: {copied_bytes / 1e9:.2f} / {total / 1e9:.2f} GB ({pct}%, {rate_mb:.0f} MB/s)"
            print(f"  [{label}] {msg}", flush=True)
            if update_status:
                write_status(f"SYNCING:{msg}")

    done_parallel = False
    if parallel_read and total >= 64 * 1024 * 1024 and hasattr(os, "pread") and hasattr(os, "pwrite"):
        src_fd = -1
        dst_fd = -1
        try:
            src_fd = os.open(src, os.O_RDONLY)
            dst_fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
            os.ftruncate(dst_fd, total)
            chunk_size = 16 * 1024 * 1024
            ranges = [
                (off, min(chunk_size, total - off))
                for off in range(0, total, chunk_size)
            ]

            def copy_range(offset: int, length: int) -> None:
                nonlocal copied
                pos = offset
                rem = length
                while rem > 0:
                    buf = os.pread(src_fd, min(4 * 1024 * 1024, rem), pos)
                    if not buf:
                        raise EOFError(f"Unexpected EOF reading {src} at {pos}")
                    w_off = 0
                    while w_off < len(buf):
                        n = os.pwrite(dst_fd, buf[w_off:], pos + w_off)
                        if n <= 0:
                            raise OSError(f"Short pwrite to {tmp} at {pos + w_off}")
                        w_off += n
                    pos += len(buf)
                    rem -= len(buf)
                    with lock:
                        copied += len(buf)
                        report(copied)

            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                futures = [pool.submit(copy_range, off, length) for off, length in ranges]
                for fut in futures:
                    fut.result()

            os.fsync(dst_fd)
            done_parallel = True
        except OSError:
            copied = 0
            try:
                if os.path.exists(tmp):
                    os.remove(tmp)
            except OSError:
                pass
        finally:
            if src_fd >= 0:
                try:
                    os.close(src_fd)
                except OSError:
                    pass
            if dst_fd >= 0:
                try:
                    os.close(dst_fd)
                except OSError:
                    pass

    if not done_parallel:
        with open(src, "rb") as fsrc, open(tmp, "wb") as fdst:
            while True:
                buf = fsrc.read(16 * 1024 * 1024)
                if not buf:
                    break
                fdst.write(buf)
                copied += len(buf)
                report(copied)
            fdst.flush()
            os.fsync(fdst.fileno())

    os.replace(tmp, dst)
    try:
        shutil.copystat(src, dst)
    except OSError:
        pass


def _json_canonical_bytes(obj: dict) -> bytes:
    return (json.dumps(obj, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def sanitize_run_config(raw: bytes) -> bytes | None:
    try:
        data = json.loads(raw.decode("utf-8-sig"))
    except Exception:
        return None
    if not isinstance(data, dict):
        return None
    data.pop("api_key", None)
    return _json_canonical_bytes(data)


def sanitize_desktop_state(raw: bytes) -> bytes | None:
    try:
        data = json.loads(raw.decode("utf-8-sig"))
    except Exception:
        return None
    if not isinstance(data, dict):
        return None
    if isinstance(data.get("serving"), dict):
        data["serving"]["apiKey"] = None
    return _json_canonical_bytes(data)


def sync_bytes_if_changed(dst: str, payload: bytes, local_mode: int | None = None) -> bool:
    if os.path.isfile(dst):
        try:
            with open(dst, "rb") as f:
                if f.read() == payload:
                    return False
        except OSError:
            pass
    write_file_atomic(dst, payload, mode=local_mode)
    return True


def _sync_dir_files(src_dir: str, dst_dir: str, *, json_only: bool = False) -> int:
    if not os.path.isdir(src_dir):
        return 0
    changed = 0
    for fn in sorted(os.listdir(src_dir)):
        if fn.startswith(".") or fn in SKIP_CONFIG_NAMES or fn.endswith(SKIP_SUFFIXES):
            continue
        if json_only and not fn.endswith(".json"):
            continue
        src = os.path.join(src_dir, fn)
        if not os.path.isfile(src):
            continue
        try:
            with open(src, "rb") as f:
                raw = f.read()
            if sync_bytes_if_changed(os.path.join(dst_dir, fn), raw):
                changed += 1
        except OSError:
            pass
    return changed


def _run_config_paths(remote_dir: str) -> list[str]:
    paths = glob.glob(os.path.join(remote_dir, "strata-*.json")) + glob.glob(
        os.path.join(remote_dir, "terminal", "strata-*.json")
    )
    return sorted(p for p in paths if os.path.isfile(p))


def cmd_sync_config(drive_dir: str, remote_dir: str) -> int:
    drive_parent = os.path.dirname(drive_dir.rstrip("/"))
    if not os.path.isdir(drive_parent):
        return 0
    slug = detect_gpu_slug()
    cfg_root = os.path.join(drive_dir, "strata-config", slug)
    presets_dst = os.path.join(cfg_root, "presets")

    changed = 0
    changed += _sync_dir_files(PRESET_DIR, presets_dst, json_only=False)
    changed += _sync_dir_files(PROFILE_DIR, os.path.join(cfg_root, "profiles"), json_only=True)

    run_cfgs_dst = os.path.join(cfg_root, "run-configs")
    for src in _run_config_paths(remote_dir):
        try:
            with open(src, "rb") as f:
                payload = sanitize_run_config(f.read())
            if payload is not None and sync_bytes_if_changed(
                os.path.join(run_cfgs_dst, os.path.basename(src)), payload
            ):
                changed += 1
        except OSError:
            pass

    if os.path.isfile(DESKTOP_STATE_FILE):
        try:
            with open(DESKTOP_STATE_FILE, "rb") as f:
                payload = sanitize_desktop_state(f.read())
            if payload is not None and sync_bytes_if_changed(
                os.path.join(cfg_root, "desktop", "state.json"), payload
            ):
                changed += 1
        except OSError:
            pass

    preset_count = 0
    if os.path.isdir(presets_dst):
        preset_count = sum(
            1
            for fn in os.listdir(presets_dst)
            if fn.endswith(".json") and fn != "active.json" and os.path.isfile(os.path.join(presets_dst, fn))
        )

    if changed > 0:
        print(f"[config-sync] Synced {changed} file(s) to {cfg_root}", flush=True)
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        write_config_status(f"SYNCED:{slug}:{preset_count}_presets:{ts}")
    elif preset_count > 0 and not os.path.isfile(CONFIG_STATUS_FILE):
        write_config_status(f"UP_TO_DATE:{slug}:{preset_count}_presets")
    return 0


def _restore_dir_files(
    src_dir: str,
    dst_dir: str,
    *,
    json_only: bool = False,
    only_if_missing: bool = False,
) -> int:
    if not os.path.isdir(src_dir):
        return 0
    restored = 0
    for fn in sorted(os.listdir(src_dir)):
        if fn.startswith(".") or fn in SKIP_CONFIG_NAMES or fn.endswith(SKIP_SUFFIXES):
            continue
        if json_only and not fn.endswith(".json"):
            continue
        src = os.path.join(src_dir, fn)
        if not os.path.isfile(src):
            continue
        dst = os.path.join(dst_dir, fn)
        if only_if_missing and os.path.exists(dst):
            continue
        try:
            st = os.stat(src)
            if os.path.isfile(dst):
                dst_st = os.stat(dst)
                if st.st_mtime <= dst_st.st_mtime + 1e-6:
                    continue
            with open(src, "rb") as f:
                payload = f.read()
            if sync_bytes_if_changed(dst, payload, local_mode=0o600):
                try:
                    os.utime(dst, (st.st_atime, st.st_mtime))
                except OSError:
                    pass
                restored += 1
        except OSError:
            pass
    return restored


def _arg_val(args: list, flag: str) -> str | None:
    for i in range(len(args) - 1):
        if str(args[i]) == flag:
            return str(args[i + 1])
    return None


def _set_arg_val(args: list, flag: str, value: str) -> None:
    for i in range(len(args) - 1):
        if str(args[i]) == flag:
            args[i + 1] = value


def _find_active_preset_goal(
    model_name: str,
    ctx_int: int | None,
    *,
    model_id_hint: str = "",
    preferred_profile: str = "",
) -> str | None:
    idx_path = os.path.join(PRESET_DIR, "active.json")
    if not os.path.isfile(idx_path):
        return None
    try:
        with open(idx_path, "r", encoding="utf-8-sig") as f:
            idx = json.load(f)
    except Exception:
        return None
    if not isinstance(idx, dict):
        return None

    m_low = model_name.strip().lower()
    hint_low = model_id_hint.strip().lower()
    pref_goal = "room" if preferred_profile == "work" else ("speed" if preferred_profile == "performance" else "")

    matches: list[tuple[int, float, str]] = []
    for entry in idx.values():
        if not isinstance(entry, dict):
            continue
        pid = entry.get("active")
        if not pid or not isinstance(pid, str):
            continue
        pfile = os.path.join(PRESET_DIR, f"{pid}.json")
        if not os.path.isfile(pfile):
            continue
        try:
            with open(pfile, "r", encoding="utf-8-sig") as f:
                preset = json.load(f)
        except Exception:
            continue
        choices = preset.get("choices") or {}
        pm = str(choices.get("model") or "").strip().lower()
        pctx = choices.get("context")
        goal = choices.get("goal")
        if goal not in ("room", "speed"):
            continue
        if ctx_int is not None and pctx != ctx_int:
            continue
        if m_low:
            if pm != m_low and not (hint_low and hint_low in pm):
                continue
        elif hint_low:
            if hint_low not in pm:
                continue
        pref_score = 1 if (pref_goal and goal == pref_goal) else 0
        created = float(preset.get("created_epoch") or 0.0)
        matches.append((pref_score, created, goal))

    if not matches:
        return None
    matches.sort(key=lambda item: (item[0], item[1]), reverse=True)
    return matches[0][2]


def cmd_restore_config(
    drive_dir: str,
    remote_dir: str,
    phase: str,
    context: str = "",
    port: str = "",
    ui_mode: str = "desktop",
) -> int:
    slug = detect_gpu_slug()
    cfg_root = os.path.join(drive_dir, "strata-config", slug) if drive_dir else ""

    if phase == "pre":
        if not cfg_root or not os.path.isdir(cfg_root):
            return 0
        n = 0
        n += _restore_dir_files(os.path.join(cfg_root, "presets"), PRESET_DIR, json_only=False)
        n += _restore_dir_files(os.path.join(cfg_root, "profiles"), PROFILE_DIR, json_only=True)
        n += _restore_dir_files(
            os.path.join(cfg_root, "desktop"),
            os.path.dirname(DESKTOP_STATE_FILE),
            json_only=True,
            only_if_missing=True,
        )
        if n > 0:
            print(f"[remote] Restored {n} tuned preset/config file(s) for {slug} from Google Drive.", flush=True)
        return 0

    if phase == "post":
        saved_dir = os.path.join(cfg_root, "run-configs") if cfg_root else ""
        ctx_int = int(context) if context and context.isdigit() else None
        applied_any = False

        for local_path in _run_config_paths(remote_dir):
            try:
                with open(local_path, "r", encoding="utf-8-sig") as f:
                    cfg = json.load(f)
            except Exception:
                continue
            if not isinstance(cfg, dict):
                continue

            saved_path = os.path.join(saved_dir, os.path.basename(local_path)) if saved_dir else ""
            if saved_dir and os.path.isdir(saved_dir) and os.path.isfile(saved_path):
                try:
                    with open(saved_path, "r", encoding="utf-8-sig") as f:
                        saved = json.load(f)
                except Exception:
                    saved = None
                if isinstance(saved, dict) and saved.get("model_name") == cfg.get("model_name"):
                    saved_args = saved.get("args") if isinstance(saved.get("args"), list) else []
                    native_path = _arg_val(saved_args, "--native")
                    native_ok = (not native_path) or os.path.isfile(native_path)
                    if native_ok:
                        saved_ctx = _arg_val(saved_args, "--max-context")
                        if not context or saved_ctx == context:
                            if saved_args:
                                cfg["args"] = list(saved_args)
                            if isinstance(saved.get("args_written"), list) and saved["args_written"]:
                                cfg["args_written"] = list(saved["args_written"])
                        for key in SAFE_PERSISTENT_KEYS:
                            if key in saved and saved[key] is not None:
                                cfg[key] = saved[key]
                        applied_any = True

            if context:
                for k in ("args", "args_written"):
                    arr = cfg.get(k)
                    if isinstance(arr, list):
                        _set_arg_val(arr, "--max-context", context)
            if port and ui_mode == "desktop":
                try:
                    cfg["port"] = int(port)
                except ValueError:
                    pass
                cfg["ui_context_chosen"] = True

            if not cfg.get("ui_resource_profile"):
                goal = _find_active_preset_goal(str(cfg.get("model_name") or ""), ctx_int)
                if goal == "room":
                    cfg["ui_resource_profile"] = "work"
                    applied_any = True
                elif goal == "speed":
                    cfg["ui_resource_profile"] = "performance"
                    applied_any = True

            try:
                write_file_atomic(local_path, _json_canonical_bytes(cfg))
            except OSError:
                pass

        if applied_any:
            print(f"[remote] Applied persisted GPU config/preset alignment for {slug}.", flush=True)
        return 0

    return 1


def cmd_load_profile(remote_dir: str, model_id: str, context: str = "") -> int:
    ctx_int = int(context) if context and context.isdigit() else None
    target_name = f"strata-{model_id.lower()}.json"
    matched_cfg: dict = {}

    for p in _run_config_paths(remote_dir):
        if os.path.basename(p).lower() == target_name:
            try:
                with open(p, "r", encoding="utf-8-sig") as f:
                    matched_cfg = json.load(f)
            except Exception:
                matched_cfg = {}
            break

    if not matched_cfg:
        for p in _run_config_paths(remote_dir):
            try:
                with open(p, "r", encoding="utf-8-sig") as f:
                    cand = json.load(f)
                if str(cand.get("model_name") or "").lower() == model_id.lower():
                    matched_cfg = cand
                    break
            except Exception:
                pass

    model_name = str(matched_cfg.get("model_name") or "")
    ui_profile = str(matched_cfg.get("ui_resource_profile") or "")
    goal = _find_active_preset_goal(
        model_name,
        ctx_int,
        model_id_hint=model_id,
        preferred_profile=ui_profile,
    )
    if goal == "room":
        print("work")
        return 0
    if goal == "speed":
        print("performance")
        return 0
    if ui_profile in ("work", "performance"):
        print(ui_profile)
        return 0
    return 0


def cmd_restore(drive_dir: str, data_dir: str, model: str) -> int:
    if not os.path.isdir(drive_dir):
        return 0
    candidates = []
    for root, _, files in os.walk(drive_dir):
        rel_root = os.path.relpath(root, drive_dir).replace("\\", "/")
        if rel_root == "strata-config" or rel_root.startswith("strata-config/"):
            continue
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
            copy_with_progress(src, dst, "Drive -> SSD", update_status=False, parallel_read=True)
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
            if "strata-drive-cache.py" in cmd:
                continue
            if any(marker in cmd for marker in CALIBRATE_MARKERS):
                return True
    except Exception:
        pass
    return False


def cmd_watch_config(drive_dir: str, remote_dir: str) -> int:
    drive_parent = os.path.dirname(drive_dir.rstrip("/"))
    if not os.path.isdir(drive_parent):
        return 0
    while True:
        try:
            if is_calibrating():
                write_config_status("WAITING_FOR_TUNE")
            else:
                cmd_sync_config(drive_dir, remote_dir)
        except Exception:
            pass
        time.sleep(15)


def cmd_backup_loop(data_dir: str, drive_dir: str, port: str, remote_dir: str = "") -> int:
    drive_parent = os.path.dirname(drive_dir.rstrip("/"))
    if not os.path.isdir(drive_parent):
        return 0
    os.makedirs(drive_dir, exist_ok=True)
    write_status("IDLE")
    synced_any = False
    initial_done = False
    no_space = False

    while True:
        time.sleep(12)
        if is_calibrating():
            write_config_status("WAITING_FOR_TUNE")
            continue
        if not os.path.isdir(data_dir):
            if remote_dir:
                cmd_sync_config(drive_dir, remote_dir)
            continue

        healthy = is_healthy(port)
        pending = []
        if not no_space:
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
                    write_config_status("WAITING_FOR_TUNE")
                    break
                free_bytes = shutil.disk_usage(drive_dir).free
                if size + (512 * 1024 * 1024) > free_bytes:
                    write_status(f"NO_SPACE:{size / 1e9:.1f}:{free_bytes / 1e9:.1f}")
                    no_space = True
                    initial_done = True
                    break
                try:
                    copy_with_progress(full, dst, "SSD -> Drive", update_status=True)
                    if os.path.isfile(full + ".done"):
                        shutil.copy2(full + ".done", dst + ".done")
                    synced_any = True
                except Exception as e:
                    write_status(f"ERROR:{e}")

        if healthy and not pending and not is_calibrating():
            if remote_dir:
                cmd_sync_config(drive_dir, remote_dir)
            if not initial_done:
                write_status("DONE" if synced_any else "CACHED")
                initial_done = True


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) >= 2 else ""
    if cmd == "restore" and len(sys.argv) >= 5:
        sys.exit(cmd_restore(sys.argv[2], sys.argv[3], sys.argv[4]))
    if cmd == "restore-config" and len(sys.argv) >= 5:
        sys.exit(cmd_restore_config(sys.argv[2], sys.argv[3], sys.argv[4], *sys.argv[5:8]))
    if cmd == "sync-config" and len(sys.argv) >= 4:
        sys.exit(cmd_sync_config(sys.argv[2], sys.argv[3]))
    if cmd == "watch-config" and len(sys.argv) >= 4:
        sys.exit(cmd_watch_config(sys.argv[2], sys.argv[3]))
    if cmd == "load-profile" and len(sys.argv) >= 4:
        sys.exit(cmd_load_profile(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) >= 5 else ""))
    if cmd == "backup" and len(sys.argv) >= 5:
        sys.exit(cmd_backup_loop(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] if len(sys.argv) >= 6 else ""))
    if cmd == "gpu-slug":
        print(detect_gpu_slug())
        sys.exit(0)
    sys.exit(1)
PYEOF
chmod +x "$DRIVE_CACHE_SCRIPT"

pkill -f "[s]trata-drive-cache.py backup" 2>/dev/null || true
pkill -f "[s]trata-drive-cache.py watch-config" 2>/dev/null || true
rm -f "$DRIVE_SYNC_STATUS" "$DRIVE_CONFIG_STATUS"

RESTORE_CMD=""
POST_DRIVE_DIR=""
if [[ "$USE_DRIVE" == 1 ]]; then
    if [[ "${DRIVE_MODEL_CACHE:-0}" == 1 ]]; then
        RESTORE_CMD="$PY $DRIVE_CACHE_SCRIPT restore-config $(printf '%q ' "$DRIVE_DATA_DIR" "$REMOTE_DIR") pre && $PY $DRIVE_CACHE_SCRIPT restore $(printf '%q ' "$DRIVE_DATA_DIR" "$DATA_DIR" "$MODEL") && "
    else
        RESTORE_CMD="$PY $DRIVE_CACHE_SCRIPT restore-config $(printf '%q ' "$DRIVE_DATA_DIR" "$REMOTE_DIR") pre && echo '[remote] Google Drive config sync enabled (DRIVE_MODEL_CACHE=0: downloading GGUF directly from Hugging Face).' && "
    fi
    POST_DRIVE_DIR="$DRIVE_DATA_DIR"
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
    if [[ $(printf '%q' "$DRIVE_MODEL_CACHE") == 1 ]]; then
        $(printf '%q' "$PY") $(printf '%q' "$DRIVE_CACHE_SCRIPT") backup $(printf '%q ' "$DATA_DIR" "$DRIVE_DATA_DIR" "$REMOTE_PORT" "$REMOTE_DIR")>/content/strata-drive-sync.log 2>&1 &
    else
        $(printf '%q' "$PY") $(printf '%q' "$DRIVE_CACHE_SCRIPT") watch-config $(printf '%q ' "$DRIVE_DATA_DIR" "$REMOTE_DIR")>/content/strata-config-sync.log 2>&1 &
    fi
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

        $(printf '%q' "$PY") $(printf '%q' "$DRIVE_CACHE_SCRIPT") restore-config $(printf '%q ' "$POST_DRIVE_DIR" "$REMOTE_DIR") post $(printf '%q ' "$CONTEXT" "$ENGINE_PORT" "$UI_MODE")

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
                LOAD_PROFILE=\$($(printf '%q' "$PY") $(printf '%q' "$DRIVE_CACHE_SCRIPT") load-profile $(printf '%q' "$REMOTE_DIR") "\$MODEL_ID" $(printf '%q' "$CONTEXT") 2>/dev/null || true)
                if [[ -n "\$LOAD_PROFILE" ]]; then
                    curl -sf -X POST "http://127.0.0.1:$REMOTE_PORT/api/native/operations" -H 'Content-Type: application/json' \
                        -d "{\"kind\":\"load\",\"args\":{\"model\":\"\$MODEL_ID\",\"resourceProfile\":\"\$LOAD_PROFILE\"}}" >/dev/null 2>&1 || true
                else
                    curl -sf -X POST "http://127.0.0.1:$REMOTE_PORT/api/native/operations" -H 'Content-Type: application/json' \
                        -d "{\"kind\":\"load\",\"args\":{\"model\":\"\$MODEL_ID\"}}" >/dev/null 2>&1 || true
                fi
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
