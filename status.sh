#!/usr/bin/env bash
# ==============================================================================
# Display Colab Runtime, Hardware, Strata Status, Drive Cache & Tunnel State
# ==============================================================================
# Pass --json to emit a single machine-readable JSON object for UI telemetry.
source "$(dirname "$0")/lib/common.sh"

JSON_MODE=0
for _arg in "$@"; do
    case "$_arg" in
        --json) JSON_MODE=1 ;;
    esac
done
unset _arg

require_cmds colab ssh curl

if (( JSON_MODE == 1 )); then
    tunnel_connected=0
    local_healthy && tunnel_connected=1 || true

    workload_active=0
    workload_monitor_running && workload_active=1 || true

    info_json=""
    runtime_active=0
    if py="$(colab_python 2>/dev/null)"; then
        info_json="$("$py" "$ROOT/lib/colab-helper.py" info --json --session "$COLAB_SESSION" 2>/dev/null || true)"
    fi

    if [[ -n "$info_json" ]]; then
        if INFO_JSON="$info_json" python3 -c 'import json, os, sys; d = json.loads(os.environ["INFO_JSON"]); sys.exit(0 if d.get("runtime_active") else 1)' 2>/dev/null; then
            runtime_active=1
        fi
    else
        session_exists && runtime_active=1 || true
    fi

    remote_json=""
    if (( runtime_active == 1 )); then
        remote_json="$(rssh_direct "STRATA_REMOTE_PORT=$(printf '%q' "$REMOTE_PORT") python3 -" <<'PY' 2>/dev/null || true
import json, os, subprocess, urllib.request

out = {
    "gpu_name": "",
    "vram_used_mib": 0,
    "vram_total_mib": 0,
    "gpu_util_pct": None,
    "gpu_temp_c": None,
    "strata_running": False,
    "active_model": "",
    "drive_sync": "",
}

try:
    smi = subprocess.check_output(
        [
            "nvidia-smi",
            "--query-gpu=name,memory.used,memory.total,utilization.gpu,temperature.gpu",
            "--format=csv,noheader,nounits",
        ],
        stderr=subprocess.DEVNULL,
        text=True,
        timeout=5,
    )
    first = next((ln.strip() for ln in smi.splitlines() if ln.strip()), "")
    if first:
        parts = [p.strip() for p in first.split(",")]
        if len(parts) >= 3:
            out["gpu_name"] = parts[0]
            try:
                out["vram_used_mib"] = int(float(parts[1]))
            except ValueError:
                pass
            try:
                out["vram_total_mib"] = int(float(parts[2]))
            except ValueError:
                pass
        if len(parts) >= 4:
            try:
                out["gpu_util_pct"] = int(float(parts[3]))
            except ValueError:
                pass
        if len(parts) >= 5:
            try:
                out["gpu_temp_c"] = int(float(parts[4]))
            except ValueError:
                pass
except Exception:
    pass

port = os.environ.get("STRATA_REMOTE_PORT", "8089")

def http_get(path):
    try:
        req = urllib.request.Request(
            f"http://127.0.0.1:{port}{path}",
            headers={"Accept": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=3) as resp:
            if 200 <= resp.status < 300:
                return resp.read().decode("utf-8", errors="ignore")
    except Exception:
        return None
    return None

if http_get("/health") is not None or http_get("/api/health") is not None:
    out["strata_running"] = True

def extract_native(obj):
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
            found = extract_native(sub)
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

model_id = ""
if out["strata_running"]:
    raw_v1 = http_get("/v1/models")
    if raw_v1:
        try:
            v1 = json.loads(raw_v1)
            for item in (v1.get("data") or []):
                if isinstance(item, dict) and isinstance(item.get("id"), str) and item["id"].strip():
                    model_id = item["id"].strip()
                    break
        except Exception:
            pass
    if not model_id:
        raw_nat = http_get("/api/native")
        if raw_nat:
            try:
                model_id = extract_native(json.loads(raw_nat))
            except Exception:
                pass

if not model_id:
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            args = open(f"/proc/{pid}/cmdline", "rb").read().decode("utf-8", errors="ignore").split("\x00")
        except OSError:
            continue
        if not any("strata.py" in a or "setup.sh" in a for a in args):
            continue
        m, f = "", ""
        for i, a in enumerate(args):
            if a == "--model" and i + 1 < len(args):
                m = args[i + 1]
            elif a == "--family" and i + 1 < len(args):
                f = args[i + 1]
        if m and m.upper() != "AUTO":
            model_id = f"{f}-{m}" if (f and f.lower() != "qwen") else m
            break

out["active_model"] = model_id

sync_parts = []
for label, path in (("", "/tmp/strata-drive-sync.status"), ("config:", "/tmp/strata-config-sync.status")):
    try:
        val = open(path, "r", encoding="utf-8").read().strip()
        if val:
            sync_parts.append(f"{label}{val}" if label else val)
    except OSError:
        pass
out["drive_sync"] = " | ".join(sync_parts)

print(json.dumps(out))
PY
)"
    fi

    INFO_JSON="$info_json" \
    REMOTE_JSON="$remote_json" \
    RUNTIME_ACTIVE="$runtime_active" \
    TUNNEL_CONNECTED="$tunnel_connected" \
    WORKLOAD_ACTIVE="$workload_active" \
    LOCAL_PORT_VAL="$LOCAL_PORT" \
    python3 - <<'PY'
import json, os

def parse_last_json(raw: str) -> dict:
    for line in reversed((raw or "").splitlines()):
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                obj = json.loads(line)
                if isinstance(obj, dict):
                    return obj
            except Exception:
                continue
    return {}

info = parse_last_json(os.environ.get("INFO_JSON", ""))
remote = parse_last_json(os.environ.get("REMOTE_JSON", ""))

def as_int(val, default=0):
    if val is None:
        return default
    try:
        return int(val)
    except (TypeError, ValueError):
        return default

def as_opt_int(val):
    if val is None:
        return None
    try:
        return int(val)
    except (TypeError, ValueError):
        return None

def as_opt_float(val):
    if val is None:
        return None
    try:
        return float(val)
    except (TypeError, ValueError):
        return None

eligible = info.get("eligible_gpus")
if not isinstance(eligible, list):
    eligible = []
eligible = [str(g) for g in eligible if g is not None]

result = {
    "runtime_active": os.environ.get("RUNTIME_ACTIVE") == "1",
    "gpu_name": str(remote.get("gpu_name") or ""),
    "vram_used_mib": as_int(remote.get("vram_used_mib"), 0),
    "vram_total_mib": as_int(remote.get("vram_total_mib"), 0),
    "gpu_util_pct": as_opt_int(remote.get("gpu_util_pct")),
    "gpu_temp_c": as_opt_int(remote.get("gpu_temp_c")),
    "strata_running": bool(remote.get("strata_running", False)),
    "active_model": str(remote.get("active_model") or ""),
    "tunnel_connected": os.environ.get("TUNNEL_CONNECTED") == "1",
    "local_port": as_int(os.environ.get("LOCAL_PORT_VAL"), 8080),
    "cu_balance": as_opt_float(info.get("cu_balance")),
    "cu_rate": as_opt_float(info.get("cu_rate")),
    "eligible_gpus": eligible,
    "drive_sync": str(remote.get("drive_sync") or ""),
    "workload_active": os.environ.get("WORKLOAD_ACTIVE") == "1",
}
print(json.dumps(result))
PY
    exit 0
fi

adopt_existing_session

msg st_runtime "$COLAB_SESSION"; echo
if session_exists; then
    colab status -s "$COLAB_SESSION" | sed 's/^/    /'

    msg st_vm; echo
    rssh_direct "nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu,temperature.gpu --format=csv,noheader; free -g | sed -n 2p; df -h /content | tail -n 1" \
        2>/dev/null | sed 's/^/    /' || echo "    $(msg st_ssh_fail)"
    if rssh_direct "curl -sf -m 5 http://127.0.0.1:$REMOTE_PORT/health >/dev/null 2>&1 || curl -sf -m 5 http://127.0.0.1:$REMOTE_PORT/api/health >/dev/null 2>&1" 2>/dev/null; then
        echo "    $(msg st_strata_up)"
    else
        echo "    $(msg st_strata_down)"
    fi

    if [[ "${USE_DRIVE:-1}" == 1 ]]; then
        msg st_drive "$DRIVE_DATA_DIR"; echo
        q_dd="$(printf '%q' "$DRIVE_DATA_DIR")"
        rssh_direct "if [[ -d $q_dd ]]; then find $q_dd -name '*.gguf' -printf '%p\t%s\n' 2>/dev/null | while IFS=\$'\\t' read -r p sz; do printf '%s (%s)\n' \"\$p\" \"\$(numfmt --to=iec-i --suffix=B \"\$sz\" 2>/dev/null || echo \"\${sz}B\")\"; done; if [[ -d $q_dd/strata-config ]]; then for g in $q_dd/strata-config/*; do [[ -d \"\$g\" ]] || continue; n=\$(find \"\$g/presets\" -maxdepth 1 -name '*.json' ! -name 'active.json' 2>/dev/null | wc -l); echo \"Config [\$(basename \"\$g\")]: \$n tuned preset(s)\"; done; fi; else echo 'Not mounted or empty'; fi; [[ -f /tmp/strata-drive-sync.status ]] && echo \"Sync status: \$(cat /tmp/strata-drive-sync.status)\"; [[ -f /tmp/strata-config-sync.status ]] && echo \"Config sync: \$(cat /tmp/strata-config-sync.status)\"" \
            2>/dev/null | sed 's/^/    /' || true
    fi
else
    echo "    $(msg st_none)"
fi

msg st_tunnel "$LOCAL_PORT"; echo
if local_healthy; then echo "    $(msg st_connected)"; else echo "    $(msg st_disconnected)"; fi

msg st_workload; echo
if workload_monitor_running; then
    last_wl="$(tail -n 1 "$WORKLOAD_LOG_FILE" 2>/dev/null || true)"
    echo "    Active (streaming via colab exec)${last_wl:+: $last_wl}"
else
    echo "    Idle (no kernel monitor running)"
fi

msg st_units; echo
colab usage | sed 's/^/    /'
