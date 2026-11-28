#!/usr/bin/env python3
"""Stream live active-workload telemetry inside Google Colab via `colab exec`.

Runs bounded telemetry windows ONLY while real compute work (Strata tuning,
calibration, setup/downloads, active Drive sync, or GPU compute) is active on
the VM, and exits cleanly as soon as the VM becomes idle.
"""

import glob
import json
import os
import subprocess
import time

MAX_WINDOW_SEC = int(os.environ.get("STRATA_WORKLOAD_WINDOW_SEC", "240"))
POLL_SEC = int(os.environ.get("STRATA_WORKLOAD_POLL_SEC", "20"))
IDLE_TICKS_TO_EXIT = int(os.environ.get("STRATA_WORKLOAD_IDLE_TICKS", "2"))
DRIVE_DATA_DIR = os.environ.get("DRIVE_DATA_DIR", "/content/drive/MyDrive/Strata-data")
REMOTE_DIR = os.environ.get("REMOTE_DIR", "/content/Strata")
GPU_UTIL_THRESHOLD = 5

TUNE_MARKERS = (
    "calibrate_config",
    "strata.py\x00tune",
    "strata.py\x00presets\x00recheck",
    "strata.py\x00calibrate",
    "native-tune/tune-",
)
SETUP_MARKERS = (
    "setup.sh\x00",
    "strata-drive-cache.py\x00restore",
    "npm\x00ci",
    "npm\x00run\x00build",
    "hf\x00download",
)
IGNORED_SUBSTRS = (
    "colab-workload.py",
    "strata-drive-cache.py\x00backup",
    "strata-drive-cache.py\x00watch-config",
)


def _scan_procs() -> tuple[bool, bool]:
    tuning_active = False
    setup_active = False
    try:
        for pid in os.listdir("/proc"):
            if not pid.isdigit():
                continue
            try:
                with open(f"/proc/{pid}/cmdline", "rb") as f:
                    cmd = f.read().decode("utf-8", errors="ignore")
            except OSError:
                continue
            if not cmd or any(ign in cmd for ign in IGNORED_SUBSTRS):
                continue
            if any(m in cmd for m in TUNE_MARKERS):
                tuning_active = True
            if any(m in cmd for m in SETUP_MARKERS):
                setup_active = True
            if tuning_active and setup_active:
                break
    except OSError:
        pass
    return tuning_active, setup_active


def _tune_progress() -> str | None:
    for path in sorted(glob.glob("/root/.strata/data/native-tune/tune-*.status.json")):
        try:
            with open(path, "r", encoding="utf-8") as f:
                st = json.load(f)
        except Exception:
            continue
        if st.get("state") == "running":
            done = st.get("runs_done")
            planned = st.get("runs_planned")
            mins = st.get("minutes_left")
            arm = st.get("arm") or st.get("stage") or ""
            parts = []
            if done is not None and planned:
                parts.append(f"{done}/{planned}")
            if mins is not None:
                parts.append(f"~{mins}m left")
            if arm:
                parts.append(str(arm))
            detail = ", ".join(parts) if parts else "running"
            return f"tune({detail})"
    return None


def _drive_sync_progress() -> str | None:
    try:
        with open("/tmp/strata-drive-sync.status", "r", encoding="utf-8") as f:
            line = f.readline().strip()
        if line.startswith("SYNCING:"):
            return f"drive_backup({line[len('SYNCING:'):].strip()})"
    except OSError:
        pass
    return None


def _gpu_telemetry() -> tuple[int, str]:
    try:
        out = subprocess.check_output(
            [
                "nvidia-smi",
                "--query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu",
                "--format=csv,noheader,nounits",
            ],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
        )
        for line in out.splitlines():
            parts = [p.strip() for p in line.split(",")]
            if len(parts) >= 4:
                util = int(float(parts[0]))
                vram_used = int(float(parts[1]))
                vram_total = int(float(parts[2]))
                temp = int(float(parts[3]))
                return util, f"GPU={util}% VRAM={vram_used}/{vram_total} MiB {temp}C"
    except Exception:
        pass
    return 0, "GPU=n/a"


def _sync_config_if_present() -> None:
    cache_script = "/tmp/strata-drive-cache.py"
    drive_data_dir = os.environ.get("DRIVE_DATA_DIR", DRIVE_DATA_DIR)
    remote_dir = os.environ.get("REMOTE_DIR", REMOTE_DIR)
    drive_parent = os.path.dirname(drive_data_dir.rstrip("/")) or "/"
    if not (os.path.isfile(cache_script) and os.path.isdir(drive_parent)):
        return
    try:
        subprocess.run(
            [
                "python3",
                cache_script,
                "sync-config",
                drive_data_dir,
                remote_dir,
            ],
            check=False,
            timeout=30,
        )
    except Exception:
        pass


def main() -> None:
    start = time.monotonic()
    idle_ticks = 0
    saw_tuning = False
    reported_idle_once = False

    while True:
        tuning_proc, setup_proc = _scan_procs()
        tune_str = _tune_progress()
        is_tuning = tuning_proc or (tune_str is not None)
        if saw_tuning and not is_tuning:
            print("[strata-workload] Tuning completed; syncing presets to Google Drive...", flush=True)
            _sync_config_if_present()
            saw_tuning = False
        elif is_tuning:
            saw_tuning = True

        active_tags: list[str] = []
        if tune_str:
            active_tags.append(tune_str)
        elif tuning_proc:
            active_tags.append("tune(running)")

        drive_str = _drive_sync_progress()
        if drive_str:
            active_tags.append(drive_str)
        if setup_proc:
            active_tags.append("setup")

        gpu_util, gpu_str = _gpu_telemetry()
        if gpu_util >= GPU_UTIL_THRESHOLD:
            active_tags.append("gpu_compute")

        if active_tags:
            idle_ticks = 0
            reported_idle_once = False
            ts = time.strftime("%H:%M:%S UTC", time.gmtime())
            print(f"[strata-workload {ts}] active={', '.join(active_tags)} | {gpu_str}", flush=True)
        else:
            idle_ticks += 1
            if not reported_idle_once:
                ts = time.strftime("%H:%M:%S UTC", time.gmtime())
                print(f"[strata-workload {ts}] VM idle ({gpu_str}); waiting briefly before exit...", flush=True)
                reported_idle_once = True
            if idle_ticks >= IDLE_TICKS_TO_EXIT:
                print("[strata-workload] No active compute workload detected (VM idle). Releasing Colab kernel.", flush=True)
                return

        remaining = MAX_WINDOW_SEC - (time.monotonic() - start)
        if remaining <= 0:
            print("[strata-workload] Telemetry window complete; active workload continuing.", flush=True)
            return
        time.sleep(min(POLL_SEC, remaining))


if __name__ == "__main__":
    main()
