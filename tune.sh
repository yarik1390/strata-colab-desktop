#!/usr/bin/env bash
# ==============================================================================
# Run or Monitor Strata Auto-Tune Using Colab's Official `colab exec` Channel
# ==============================================================================
# Usage: ./tune.sh [thorough|quick] [coding|chat] [work|performance]
# Streams live GPU/tuning progress in the foreground until tuning completes,
# refreshing the proxy token automatically between 4-minute telemetry windows
# and persisting the resulting preset to Google Drive.
source "$(dirname "$0")/lib/common.sh"

require_cmds colab ssh curl python3

MODE="${1:-thorough}"
USE="${2:-coding}"
PROFILE="${3:-work}"

case "$MODE" in
    thorough|quick) ;;
    *) die "Invalid mode '$MODE' (expected: thorough or quick)" ;;
esac
case "$USE" in
    coding|chat) ;;
    *) die "Invalid use '$USE' (expected: coding or chat)" ;;
esac
case "$PROFILE" in
    work|performance) ;;
    *) die "Invalid profile '$PROFILE' (expected: work or performance)" ;;
esac

adopt_existing_session
session_exists || die "$(msg runtime_missing_start "$COLAB_SESSION")"

remote_tuning_active() {
    rssh "python3 -" <<'PY' 2>/dev/null
import glob, json, os, sys
markers = (
    "calibrate_config",
    "strata.py\x00tune",
    "strata.py\x00presets\x00recheck",
    "strata.py\x00calibrate",
    "native-tune/tune-",
)
for pid in os.listdir("/proc"):
    if not pid.isdigit():
        continue
    try:
        cmd = open(f"/proc/{pid}/cmdline", "rb").read().decode("utf-8", errors="ignore")
    except OSError:
        continue
    if "colab-workload.py" in cmd or "strata-drive-cache.py" in cmd:
        continue
    if any(m in cmd for m in markers):
        sys.exit(0)
for path in glob.glob("/root/.strata/data/native-tune/tune-*.status.json"):
    try:
        if json.load(open(path, "r", encoding="utf-8")).get("state") == "running":
            sys.exit(0)
    except Exception:
        pass
sys.exit(1)
PY
}

if remote_tuning_active; then
    log "$(msg tune_already_running)"
elif remote_healthy; then
    detect_active_remote_model
    MODEL_ID="$(tr '[:upper:]' '[:lower:]' <<<"$MODEL")"
    if [[ -n "${MODEL_FAMILY:-}" && "${MODEL_FAMILY,,}" != "qwen" ]]; then
        MODEL_ID="$(tr '[:upper:]' '[:lower:]' <<<"$MODEL_FAMILY")-$MODEL_ID"
    fi
    log "$(msg tune_starting "$MODE" "$USE" "$PROFILE")"
    payload="$(python3 -c 'import json, sys; print(json.dumps({"kind": "autotune", "args": {"model": sys.argv[1], "mode": sys.argv[2], "use": sys.argv[3], "resourceProfile": sys.argv[4], "allowSmallDifferences": True}}))' "$MODEL_ID" "$MODE" "$USE" "$PROFILE")"
    resp="$(printf '%s' "$payload" | rssh "curl -sS -m 15 -w '\n%{http_code}' -X POST http://127.0.0.1:$REMOTE_PORT/api/native/operations -H 'Content-Type: application/json' --data-binary @-" 2>&1)" || true
    http_code="$(tail -n 1 <<<"$resp" | tr -dc '0-9')"
    http_body="$(sed '$d' <<<"$resp" | tr '\r\n' ' ' | cut -c1-240)"
    if [[ -z "$http_code" || "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
        warn "$(msg tune_http_error "${http_code:-err}" "${http_body:-no response}")"
        die "$(msg tune_failed_start "$LOCAL_PORT")"
    fi

    started=0
    for _ in $(seq 1 10); do
        if remote_tuning_active; then
            started=1
            break
        fi
        sleep 2
    done
    (( started == 1 )) || die "$(msg tune_failed_start "$LOCAL_PORT")"
else
    die "$(msg tune_failed_start "$LOCAL_PORT")"
fi

# Stop any background monitor and take exclusive flock ownership of `colab exec`
stop_workload_monitor
exec 9>>"$WORKLOAD_LOCK_FILE"
flock -w 15 9 || die "Could not acquire workload monitor lock ($WORKLOAD_LOCK_FILE)."
trap 'exec 9>&-' EXIT

while remote_tuning_active 9>&-; do
    colab exec -s "$COLAB_SESSION" --timeout 90 \
        --env "DRIVE_DATA_DIR=$DRIVE_DATA_DIR" \
        --env "REMOTE_DIR=$REMOTE_DIR" \
        -f "$ROOT/lib/colab-workload.py" 9>&- || {
        session_exists 9>&- || die "$(msg runtime_stopped "$COLAB_SESSION")"
        sleep 10
    }
done

log "$(msg tune_finished)"
if [[ "${USE_DRIVE:-1}" == 1 ]]; then
    rssh "if [[ -f /tmp/strata-drive-cache.py ]]; then python3 /tmp/strata-drive-cache.py sync-config $(printf '%q ' "$DRIVE_DATA_DIR" "$REMOTE_DIR"); fi" 9>&- || true
fi

rssh "python3 -" <<'PY' 2>/dev/null 9>&- || true
import json, os
idx_path = os.path.expanduser("~/.config/strata/presets/active.json")
if os.path.isfile(idx_path):
    idx = json.load(open(idx_path, "r", encoding="utf-8-sig"))
    print("Active tuned preset(s):")
    for entry in idx.values():
        pid = (entry or {}).get("active")
        pfile = os.path.expanduser(f"~/.config/strata/presets/{pid}.json") if pid else ""
        if pid and os.path.isfile(pfile):
            p = json.load(open(pfile, "r", encoding="utf-8-sig"))
            m = p.get("measured") or {}
            print(f"  - {p.get('name')} ({pid[:8]}): decode={m.get('decode_tok_s')} tok/s, gain={m.get('gain_pct')}%")
if os.path.isfile("/tmp/strata-config-sync.status"):
    print("Drive sync:", open("/tmp/strata-config-sync.status", encoding="utf-8").read().strip())
PY
