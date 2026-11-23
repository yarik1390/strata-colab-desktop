#!/usr/bin/env bash
# ==============================================================================
# Run or Monitor Strata Auto-Tune Using Colab's Official `colab exec` Channel
# ==============================================================================
# Usage: ./tune.sh [thorough|quick] [coding|chat] [work|performance]
# Streams live GPU/tuning progress in the foreground until tuning completes,
# refreshing the proxy token automatically between 4-minute telemetry windows
# and persisting the resulting preset to Google Drive.
source "$(dirname "$0")/lib/common.sh"

require_cmds colab ssh curl

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
    MODEL_ID="$(tr '[:upper:]' '[:lower:]' <<<"$MODEL")"
    if [[ -n "${MODEL_FAMILY:-}" && "${MODEL_FAMILY,,}" != "qwen" ]]; then
        MODEL_ID="$(tr '[:upper:]' '[:lower:]' <<<"$MODEL_FAMILY")-$MODEL_ID"
    fi
    log "$(msg tune_starting "$MODE" "$USE" "$PROFILE")"
    payload="{\"kind\":\"autotune\",\"args\":{\"model\":\"$MODEL_ID\",\"mode\":\"$MODE\",\"use\":\"$USE\",\"resourceProfile\":\"$PROFILE\",\"allowSmallDifferences\":true}}"
    printf '%s' "$payload" | rssh "curl -sf -X POST http://127.0.0.1:$REMOTE_PORT/api/native/operations -H 'Content-Type: application/json' --data-binary @- >/dev/null" || true

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

# Own the foreground `colab exec` stream while tuning runs
stop_workload_monitor

while remote_tuning_active; do
    colab exec -s "$COLAB_SESSION" --timeout 90 -f "$ROOT/lib/colab-workload.py" || {
        session_exists || die "$(msg runtime_stopped "$COLAB_SESSION")"
        sleep 10
    }
done

log "$(msg tune_finished)"
if [[ "${USE_DRIVE:-1}" == 1 ]]; then
    rssh "if [[ -f /tmp/strata-drive-cache.py ]]; then python3 /tmp/strata-drive-cache.py sync-config $(printf '%q ' "$DRIVE_DATA_DIR" "$REMOTE_DIR"); fi" || true
fi

rssh "python3 -" <<'PY' 2>/dev/null || true
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
