#!/usr/bin/env bash
# ==============================================================================
# Offline Bash Integration & Unit Test Suite for Strata Colab Desktop
# ==============================================================================
# Standalone mock harness (zero bats/external deps). Runs on Ubuntu CI & WSL.
# Uses isolated temp directories + PATH-injected mock colab/ssh/curl/ss/tmux.
set -euo pipefail

ORIG_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/strata-shell-tests.XXXXXX")"
BG_PIDS=()

cleanup() {
    local p
    for p in "${BG_PIDS[@]:-}"; do
        [[ -n "$p" ]] && kill "$p" 2>/dev/null || true
    done
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

PASS_COUNT=0
FAIL_COUNT=0
CURRENT_TEST=""

fail_msg() {
    printf '  [FAIL] %s: %s\n' "$CURRENT_TEST" "$1" >&2
    return 1
}

assert_eq() {
    local actual="$1" expected="$2" label="${3:-value}"
    if [[ "$actual" != "$expected" ]]; then
        fail_msg "$label: expected '$expected', got '$actual'"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" label="${3:-output}"
    if [[ "$haystack" != *"$needle"* ]]; then
        fail_msg "$label: expected to contain '$needle', got: $haystack"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" label="${3:-output}"
    if [[ "$haystack" == *"$needle"* ]]; then
        fail_msg "$label: expected NOT to contain '$needle', got: $haystack"
    fi
}

run_test() {
    local name="$1" fn="$2"
    CURRENT_TEST="$name"
    local err_file="$TMP_ROOT/err-${fn}.log"
    if ( "$fn" ) 2>"$err_file"; then
        PASS_COUNT=$((PASS_COUNT + 1))
        printf '[PASS] %s\n' "$name"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf '[FAIL] %s\n' "$name"
        if [[ -s "$err_file" ]]; then
            sed 's/^/       /' "$err_file" >&2
        fi
    fi
}

# Create a hermetic copy of the scripts + empty HOME + mock bin dir for one test case.
make_sandbox() {
    local name="$1"
    local dir="$TMP_ROOT/case-$name"
    mkdir -p "$dir/repo/lib" "$dir/home/.ssh" "$dir/bin" "$dir/logs"
    cp "$ORIG_REPO/config.env" "$ORIG_REPO/ssh_config" \
       "$ORIG_REPO/status.sh" "$ORIG_REPO/down.sh" "$ORIG_REPO/ssh.sh" \
       "$ORIG_REPO/up.sh" "$ORIG_REPO/tune.sh" "$dir/repo/"
    cp "$ORIG_REPO/lib/common.sh" "$ORIG_REPO/lib/messages.sh" \
       "$ORIG_REPO/lib/colab-helper.py" "$ORIG_REPO/lib/colab-workload.py" \
       "$dir/repo/lib/"

    # Default benign stubs for external commands so nothing touches live Colab/network.
    cat > "$dir/bin/colab" <<'EOF'
#!/usr/bin/env bash
echo "colab $*" >> "${MOCK_LOG_DIR:?}/colab.log"
case "${1:-}" in
    status) echo "Session strata: running"; exit 0 ;;
    stop)   echo "Stopped"; exit 0 ;;
    usage)  echo "Current balance: 100.00"; echo "Active assignments: 0"; exit 0 ;;
    *)      exit 0 ;;
esac
EOF
    cat > "$dir/bin/ssh" <<'EOF'
#!/usr/bin/env bash
echo "ssh $*" >> "${MOCK_LOG_DIR:?}/ssh.log"
exit 0
EOF
    cat > "$dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "${MOCK_LOG_DIR:?}/curl.log"
exit 22
EOF
    cat > "$dir/bin/ss" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat > "$dir/bin/tmux" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$dir/bin/colab" "$dir/bin/ssh" "$dir/bin/curl" "$dir/bin/ss" "$dir/bin/tmux"
    echo "$dir"
}

# Run a bash snippet with clean caller env (no leaked Strata vars from outer shell).
clean_env_bash() {
    local sandbox="$1"
    shift
    env -i \
        HOME="$sandbox/home" \
        PATH="$sandbox/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        MOCK_LOG_DIR="$sandbox/logs" \
        TERM=dumb \
        "$@"
}

# ==============================================================================
# 1. lib/common.sh tests
# ==============================================================================

test_common_crlf_config() {
    local sb
    sb="$(make_sandbox crlf)"
    python3 -B - "$ORIG_REPO/config.env" "$sb/repo/config.env" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
raw = open(src, "rb").read().replace(b"\r\n", b"\n")
extra = (
    b"\nCOLAB_SESSION=crlf-test\n"
    b"GPU=L4\n"
    b"LOCAL_PORT=9191\n"
    b"REMOTE_PORT=8099\n"
    b"MODEL=IQ2_XS\n"
    b"MODEL_FAMILY=qwen36\n"
)
crlf = (raw + extra).replace(b"\n", b"\r\n")
open(dst, "wb").write(crlf)
PY

    local out
    out="$(clean_env_bash "$sb" bash -c '
        source "$1/repo/lib/common.sh"
        for v in COLAB_SESSION GPU LOCAL_PORT REMOTE_PORT MODEL MODEL_FAMILY; do
            val="${!v}"
            [[ "$val" != *$'\''\r'\''* ]] || { echo "CR in $v" >&2; exit 1; }
        done
        printf "%s|%s|%s|%s|%s|%s\n" "$COLAB_SESSION" "$GPU" "$LOCAL_PORT" "$REMOTE_PORT" "$MODEL" "$MODEL_FAMILY"
    ' _ "$sb")"
    assert_eq "$out" "crlf-test|L4|9191|8099|IQ2_XS|qwen36" "CRLF parsed config values"
}

test_common_caller_env_empty_string_override() {
    local sb
    sb="$(make_sandbox caller-env)"
    cat > "$sb/repo/config.local.env" <<'EOF'
MODEL_FAMILY='nvfp4'
STRATA_KV_CACHE='int8'
LOCAL_PORT=8899
EOF

    local out
    out="$(clean_env_bash "$sb" MODEL_FAMILY='' STRATA_KV_CACHE='' bash -c '
        source "$1/repo/lib/common.sh"
        printf "[%s]|[%s]|[%s]\n" "$MODEL_FAMILY" "$STRATA_KV_CACHE" "$LOCAL_PORT"
    ' _ "$sb")"
    assert_eq "$out" "[]|[]|[8899]" "empty caller env beats config.local.env while unset var keeps local override"
}

test_common_model_slot_and_auto_resolution() {
    local sb
    sb="$(make_sandbox auto-model)"

    local out
    out="$(clean_env_bash "$sb" bash -c '
        source "$1/repo/lib/common.sh"
        check_case() {
            local vram="$1" ram="$2" gname="$3" hint="$4" exp_slot="$5" exp_fam="$6" exp_model="$7"
            VM_VRAM_GB="$vram"
            VM_RAM_GB="$ram"
            VM_GPU_NAME="$gname"
            MODEL="AUTO"
            MODEL_FAMILY="stale"
            MODEL_REPO=""
            probe_vm_memory_gb() { :; }
            local slot
            slot="$(recommended_model_slot "$hint")"
            [[ "$slot" == "$exp_slot" ]] || { echo "slot mismatch for $gname/$hint: got $slot expected $exp_slot" >&2; exit 1; }
            resolve_auto_model "$hint" >/dev/null
            [[ "$MODEL_FAMILY" == "$exp_fam" && "$MODEL" == "$exp_model" ]] || {
                echo "resolve mismatch for $gname/$hint: got ($MODEL_FAMILY,$MODEL) expected ($exp_fam,$exp_model)" >&2
                exit 1
            }
        }
        # Live hardware probe cases
        check_case 98 176 "NVIDIA RTX PRO 6000 Blackwell Server Edition" "" 6 "nvfp4" "NVFP4"
        check_case 80 167 "NVIDIA H100 80GB HBM3" "" 5 "" "IQ3_S"
        check_case 40 83  "NVIDIA A100-SXM4-40GB" "" 5 "" "IQ3_S"
        check_case 23 52  "NVIDIA L4" "" 2 "" "IQ2_XS"
        check_case 15 51  "Tesla T4" "" 1 "qwen36" "UD-Q4_K_XL"
        # Fallback GPU hint cases when VM_VRAM_GB=0
        check_case 0 0 "" "G4"   6 "nvfp4" "NVFP4"
        check_case 0 0 "" "A100" 5 "" "IQ3_S"
        check_case 0 0 "" "H100" 5 "" "IQ3_S"
        check_case 0 0 "" "L4"   2 "" "IQ2_XS"
        check_case 0 0 "" "T4"   1 "qwen36" "UD-Q4_K_XL"
        echo "ALL_MODEL_SLOTS_OK"
    ' _ "$sb")"
    assert_eq "$out" "ALL_MODEL_SLOTS_OK" "recommended_model_slot and resolve_auto_model"
}

test_common_ensure_master_fd9_non_inheritance() {
    local sb
    sb="$(make_sandbox fd9)"
    local marker="$sb/logs/master.ready"
    local child_pid_file="$sb/logs/child.pid"

    cat > "$sb/bin/ssh" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
    if [[ "\$a" == "check" ]]; then
        [[ -f "$marker" ]] && exit 0 || exit 255
    fi
done
# Simulate ssh -f backgrounding a long-lived master child process.
sleep 30 </dev/null >/dev/null 2>&1 &
echo "\$!" > "$child_pid_file"
touch "$marker"
exit 0
EOF
    chmod +x "$sb/bin/ssh"

    local out
    out="$(clean_env_bash "$sb" bash -c '
        child_pid=""
        trap '\''[[ -n "$child_pid" ]] && kill "$child_pid" 2>/dev/null || true'\'' EXIT
        source "$1/repo/lib/common.sh"
        ensure_master
        child_pid="$(cat "$2")"
        kill -0 "$child_pid" 2>/dev/null || { echo "ssh child not alive" >&2; exit 1; }
        lock_file="$HOME/.ssh/colab-cm-$COLAB_SESSION.lock"
        rc=0
        ( flock -n 9 ) 9>>"$lock_file" || rc=$?
        if (( rc != 0 )); then
            echo "FD 9 leaked into background ssh child (flock -n failed)" >&2
            exit 1
        fi
        echo "FD9_NOT_INHERITED"
    ' _ "$sb" "$child_pid_file")"
    assert_eq "$out" "FD9_NOT_INHERITED" "ensure_master FD-9 non-inheritance"
}

test_common_health_checks_and_ui_state_gating() {
    local sb
    sb="$(make_sandbox health-ui)"

    # Mock ssh executes the remote command locally so mock curl handles remote_healthy too.
    cat > "$sb/bin/ssh" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
    [[ "$a" == "-O" ]] && exit 0
done
# Last argument is the remote command string.
cmd="${@: -1}"
bash -c "$cmd"
EOF
    cat > "$sb/bin/curl" <<'EOF'
#!/usr/bin/env bash
mode="${MOCK_CURL_MODE:-none}"
url="${@: -1}"
case "$mode" in
    health)     [[ "$url" == */health && "$url" != */api/health ]] && exit 0 || exit 22 ;;
    api_health) [[ "$url" == */api/health ]] && exit 0 || exit 22 ;;
    *)          exit 22 ;;
esac
EOF
    chmod +x "$sb/bin/ssh" "$sb/bin/curl"

    local out
    out="$(clean_env_bash "$sb" bash -c '
        source "$1/repo/lib/common.sh"

        MOCK_CURL_MODE=health local_healthy || { echo "local /health failed" >&2; exit 1; }
        MOCK_CURL_MODE=api_health local_healthy || { echo "local /api/health failed" >&2; exit 1; }
        ! MOCK_CURL_MODE=none local_healthy || { echo "local unhealthy returned 0" >&2; exit 1; }

        MOCK_CURL_MODE=health remote_healthy || { echo "remote /health failed" >&2; exit 1; }
        MOCK_CURL_MODE=api_health remote_healthy || { echo "remote /api/health failed" >&2; exit 1; }
        ! MOCK_CURL_MODE=none remote_healthy || { echo "remote unhealthy returned 0" >&2; exit 1; }

        STRATA_UI_HOST=0
        off_out="$(emit_ui_state "starting")"
        [[ -z "$off_out" ]] || { echo "emit_ui_state leaked when STRATA_UI_HOST=0: $off_out" >&2; exit 1; }

        STRATA_UI_HOST=1
        on_out="$(emit_ui_state "tunnel_ready")"
        [[ "$on_out" == "[STRATA_STATE:tunnel_ready]" ]] || { echo "unexpected UI state: $on_out" >&2; exit 1; }

        echo "HEALTH_AND_UI_OK"
    ' _ "$sb")"
    assert_eq "$out" "HEALTH_AND_UI_OK" "health checks and emit_ui_state gating"
}

test_common_workload_monitor_lock_exclusion() {
    local sb
    sb="$(make_sandbox wl-lock)"

    cat > "$sb/bin/colab" <<'EOF'
#!/usr/bin/env bash
echo "colab $*" >> "${MOCK_LOG_DIR:?}/colab.log"
if [[ "${1:-}" == "exec" ]]; then
    sleep 15
    exit 0
fi
exit 0
EOF
    chmod +x "$sb/bin/colab"

    local out
    out="$(clean_env_bash "$sb" bash -c '
        holder_pid=""
        trap '\''[[ -n "$holder_pid" ]] && kill "$holder_pid" 2>/dev/null || true; stop_workload_monitor 2>/dev/null || true'\'' EXIT
        source "$1/repo/lib/common.sh"
        remote_workload_active() { return 0; }

        # Hold the lock externally: workload_lock_held must be true and maybe_run_workload_monitor must not spawn colab exec.
        (
            flock 9
            sleep 15
        ) 9>>"$WORKLOAD_LOCK_FILE" &
        holder_pid=$!
        sleep 0.2

        workload_lock_held || { echo "expected lock held" >&2; exit 1; }
        maybe_run_workload_monitor
        sleep 0.2
        if grep -q "^colab exec " "$MOCK_LOG_DIR/colab.log" 2>/dev/null; then
            echo "colab exec launched while workload lock held" >&2
            exit 1
        fi
        kill "$holder_pid" 2>/dev/null || true
        wait "$holder_pid" 2>/dev/null || true
        holder_pid=""

        # Lock is now free: first call spawns exactly one colab exec, second call is suppressed.
        ! workload_lock_held || { echo "expected lock released" >&2; exit 1; }
        maybe_run_workload_monitor >/dev/null
        sleep 0.3
        workload_monitor_running || { echo "expected workload monitor running" >&2; exit 1; }
        maybe_run_workload_monitor >/dev/null
        sleep 0.2
        stop_workload_monitor

        count="$(grep -c "^colab exec " "$MOCK_LOG_DIR/colab.log" 2>/dev/null || echo 0)"
        echo "EXEC_COUNT=$count"
    ' _ "$sb")"
    assert_eq "$out" "EXEC_COUNT=1" "workload-monitor.lock mutual exclusion"
}

# ==============================================================================
# 2. status.sh --json test
# ==============================================================================

test_status_json_schema_and_call_budget() {
    local sb
    sb="$(make_sandbox status-json)"
    local fake_py_dir="$sb/home/.local/share/uv/tools/google-colab-cli/bin"
    mkdir -p "$fake_py_dir"

    cat > "$fake_py_dir/python" <<'EOF'
#!/usr/bin/env bash
echo "helper $*" >> "${MOCK_LOG_DIR:?}/helper.log"
printf '{"cu_balance": 84.25, "cu_rate": 1.96, "assignments_count": 1, "eligible_gpus": ["G4", "A100", "L4"], "ineligible_gpus": ["H100"], "runtime_active": true}\n'
EOF
    chmod +x "$fake_py_dir/python"

    cat > "$sb/bin/ssh" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
    if [[ "$a" == "-O" ]]; then
        exit 0
    fi
done
echo "ssh_cmd $*" >> "${MOCK_LOG_DIR:?}/ssh_cmd.log"
cat >/dev/null
printf '{"gpu_name": "NVIDIA RTX PRO 6000 Blackwell", "vram_used_mib": 2048, "vram_total_mib": 98304, "gpu_util_pct": 18, "gpu_temp_c": 51, "strata_running": true, "active_model": "nvfp4-nvfp4", "drive_sync": "CACHED"}\n'
EOF
    cat > "$sb/bin/curl" <<'EOF'
#!/usr/bin/env bash
[[ "${@: -1}" == */api/health ]] && exit 0 || exit 22
EOF
    chmod +x "$sb/bin/ssh" "$sb/bin/curl"

    local json_out
    json_out="$(clean_env_bash "$sb" bash "$sb/repo/status.sh" --json)"

    local info_calls ssh_calls colab_status_calls
    info_calls="$(grep -c "colab-helper.py info --json" "$sb/logs/helper.log" 2>/dev/null || echo 0)"
    ssh_calls="$(wc -l < "$sb/logs/ssh_cmd.log" 2>/dev/null | tr -d ' ' || echo 0)"
    colab_status_calls="$(grep -c "^colab status" "$sb/logs/colab.log" 2>/dev/null || echo 0)"

    assert_eq "$info_calls" "1" "status.sh --json info call count"
    assert_eq "$ssh_calls" "1" "status.sh --json ssh command count"
    assert_eq "$colab_status_calls" "0" "status.sh --json colab status call count"

    JSON_PAYLOAD="$json_out" python3 -B - <<'PY'
import json, os

data = json.loads(os.environ["JSON_PAYLOAD"])
expected_types = {
    "runtime_active": bool,
    "gpu_name": str,
    "vram_used_mib": int,
    "vram_total_mib": int,
    "gpu_util_pct": int,
    "gpu_temp_c": int,
    "strata_running": bool,
    "active_model": str,
    "tunnel_connected": bool,
    "local_port": int,
    "cu_balance": float,
    "cu_rate": float,
    "eligible_gpus": list,
    "drive_sync": str,
    "workload_active": bool,
}
assert len(data) == 15, f"Expected 15 keys, got {len(data)}: {sorted(data.keys())}"
assert set(data.keys()) == set(expected_types.keys()), f"Key mismatch: {set(data.keys()) ^ set(expected_types.keys())}"
for k, typ in expected_types.items():
    val = data[k]
    if typ is int:
        assert type(val) is int, f"{k} expected int, got {type(val).__name__}"
    elif typ is float:
        assert isinstance(val, (int, float)) and not isinstance(val, bool), f"{k} expected float, got {type(val).__name__}"
    else:
        assert isinstance(val, typ), f"{k} expected {typ.__name__}, got {type(val).__name__}"

assert data["runtime_active"] is True
assert data["strata_running"] is True
assert data["tunnel_connected"] is True
assert data["gpu_name"] == "NVIDIA RTX PRO 6000 Blackwell"
assert data["vram_used_mib"] == 2048
assert data["vram_total_mib"] == 98304
assert data["local_port"] == 8080
assert data["eligible_gpus"] == ["G4", "A100", "L4"]
assert data["drive_sync"] == "CACHED"
PY
}

# ==============================================================================
# 3. down.sh stale SYNCING test
# ==============================================================================

test_down_stale_syncing_exits_immediately_and_stops() {
    local sb
    sb="$(make_sandbox down-stale)"

    cat > "$sb/bin/ssh" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
    [[ "$a" == "-O" ]] && exit 0
done
cmd="${@: -1}"
if [[ "$cmd" == *"strata-drive-sync.status"* ]]; then
    printf 'DEAD\nSYNCING:model.gguf: 12.5 / 60.0 GB (20%%)\n'
    exit 0
fi
exit 0
EOF
    chmod +x "$sb/bin/ssh"

    local t0 t1 elapsed out
    t0="$(date +%s)"
    out="$(clean_env_bash "$sb" USE_DRIVE=1 DRIVE_MODEL_CACHE=1 bash "$sb/repo/down.sh" 2>&1)"
    t1="$(date +%s)"
    elapsed=$((t1 - t0))

    if (( elapsed > 4 )); then
        fail_msg "down.sh took ${elapsed}s on stale SYNCING status (expected immediate exit)"
    fi
    assert_contains "$out" "stale SYNCING status" "down.sh stale warning"
    if ! grep -q "^colab stop -s strata$" "$sb/logs/colab.log"; then
        fail_msg "down.sh did not invoke 'colab stop -s strata'"
    fi
}

# ==============================================================================
# 4. ssh.sh flag forwarding test
# ==============================================================================

test_ssh_flag_forwarding() {
    local sb
    sb="$(make_sandbox ssh-flags)"

    cat > "$sb/bin/ssh" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
    if [[ "$a" == "-O" ]]; then
        if [[ "${MOCK_RECORD_CTL:-0}" == 1 ]]; then
            printf '%s\n' "$@" > "${MOCK_LOG_DIR:?}/ssh-argv.txt"
        fi
        exit 0
    fi
done
printf '%s\n' "$@" > "${MOCK_LOG_DIR:?}/ssh-argv.txt"
exit 0
EOF
    chmod +x "$sb/bin/ssh"

    # Case 1: -t before remote command containing another -t
    clean_env_bash "$sb" bash "$sb/repo/ssh.sh" -t tmux attach -t strata
    local joined
    joined="$(paste -sd'|' "$sb/logs/ssh-argv.txt")"
    assert_eq "$joined" "-F|$sb/repo/ssh_config|-t|colab-strata|tmux|attach|-t|strata" "ssh.sh -t forwarding"

    # Case 2: -L, -o, -p with arguments + remote command with flag
    clean_env_bash "$sb" bash "$sb/repo/ssh.sh" -L 9000:127.0.0.1:8089 -o ServerAliveInterval=15 -p 2222 nvidia-smi -L
    joined="$(paste -sd'|' "$sb/logs/ssh-argv.txt")"
    assert_eq "$joined" \
        "-F|$sb/repo/ssh_config|-L|9000:127.0.0.1:8089|-o|ServerAliveInterval=15|-p|2222|colab-strata|nvidia-smi|-L" \
        "ssh.sh -L/-o/-p forwarding"

    # Case 3: -- separator stops option parsing cleanly
    clean_env_bash "$sb" bash "$sb/repo/ssh.sh" -t -- -o literal-arg --help
    joined="$(paste -sd'|' "$sb/logs/ssh-argv.txt")"
    assert_eq "$joined" \
        "-F|$sb/repo/ssh_config|-t|colab-strata|-o|literal-arg|--help" \
        "ssh.sh -- separator forwarding"
}

# ==============================================================================
# 5. up.sh tests (non-TTY check_gpu guard, ^ASSIGNED_GPU= parsing, exit code 4)
# ==============================================================================

test_up_assigned_gpu_parsing_and_nontty_check_gpu_guard() {
    local sb
    sb="$(make_sandbox up-guard)"
    local fake_py_dir="$sb/home/.local/share/uv/tools/google-colab-cli/bin"
    mkdir -p "$fake_py_dir"

    cat > "$fake_py_dir/python" <<'EOF'
#!/usr/bin/env bash
case "${2:-}" in
    info)
        echo "    Current balance: 99.00 compute units"
        echo "ELIGIBLE_GPUS=G4 L4 T4"
        exit 0
        ;;
    adopt)
        exit 1
        ;;
    auto-assign)
        echo "[STRATA_STATE:probing:G4]"
        echo "noise prefix ASSIGNED_GPU=T4:HIGH_RAM"
        echo "ASSIGNED_GPU=L4:STANDARD"
        exit 0
        ;;
esac
exit 1
EOF
    chmod +x "$fake_py_dir/python"

    cat > "$sb/bin/ssh" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
    [[ "$a" == "-O" ]] && exit 0
done
cmd="${@: -1}"
if [[ "$cmd" == *"nvidia-smi"* ]]; then
    # Deliberately return Tesla T4: mismatches L4 (would have matched T4 if noise line had been parsed!)
    echo "Tesla T4, 15360 MiB"
    exit 0
fi
exit 0
EOF
    chmod +x "$sb/bin/ssh"

    local t0 t1 elapsed out rc=0
    t0="$(date +%s)"
    out="$(clean_env_bash "$sb" GPU=AUTO ASK_GPU=0 ON_GPU_MISMATCH=ask STRATA_UI_HOST=1 \
        bash "$sb/repo/up.sh" </dev/null 2>&1)" || rc=$?
    t1="$(date +%s)"
    elapsed=$((t1 - t0))

    if (( rc == 0 )); then
        fail_msg "expected up.sh to abort on GPU mismatch in non-TTY mode"
    fi
    if (( elapsed > 5 )); then
        fail_msg "up.sh non-TTY check_gpu took ${elapsed}s (expected fast abort, no hang)"
    fi
    assert_contains "$out" "[STRATA_STATE:probing:G4]" "up.sh passes UI probing marker"
    assert_contains "$out" "Allocated L4 (STANDARD shape)." "up.sh parses ^ASSIGNED_GPU=L4:STANDARD (ignoring mid-line noise)"
    assert_contains "$out" "does not match expected pattern (L4)" "up.sh sets EXPECT_GPU_REGEX from parsed GPU"
    assert_contains "$out" "Non-interactive session detected" "up.sh non-TTY check_gpu guard message"
    if ! grep -q "^colab stop -s strata$" "$sb/logs/colab.log"; then
        fail_msg "up.sh did not stop mismatched runtime via 'colab stop -s strata'"
    fi
}

test_up_exit_code_4_stops_without_looping() {
    local sb
    sb="$(make_sandbox up-rc4)"
    local fake_py_dir="$sb/home/.local/share/uv/tools/google-colab-cli/bin"
    mkdir -p "$fake_py_dir"

    cat > "$fake_py_dir/python" <<'EOF'
#!/usr/bin/env bash
echo "helper $*" >> "${MOCK_LOG_DIR:?}/helper.log"
case "${2:-}" in
    info)
        echo "ELIGIBLE_GPUS=G4 A100 T4"
        exit 0
        ;;
    adopt)
        exit 1
        ;;
    auto-assign|assign)
        exit 4
        ;;
esac
exit 1
EOF
    chmod +x "$fake_py_dir/python"

    # Case A: AUTO waterfall exit code 4
    local out rc=0 calls
    out="$(clean_env_bash "$sb" GPU=AUTO ASK_GPU=0 bash "$sb/repo/up.sh" </dev/null 2>&1)" || rc=$?
    if (( rc == 0 )); then
        fail_msg "up.sh (AUTO) should fail on exit code 4"
    fi
    assert_contains "$out" "TooManyAssignmentsError" "up.sh AUTO exit 4 error message"
    calls="$(grep -c "auto-assign" "$sb/logs/helper.log" 2>/dev/null || echo 0)"
    assert_eq "$calls" "1" "up.sh AUTO must not loop after exit code 4"

    # Case B: explicit GPU exit code 4
    : > "$sb/logs/helper.log"
    rc=0
    out="$(clean_env_bash "$sb" GPU=A100 ASK_GPU=0 bash "$sb/repo/up.sh" </dev/null 2>&1)" || rc=$?
    if (( rc == 0 )); then
        fail_msg "up.sh (explicit GPU) should fail on exit code 4"
    fi
    assert_contains "$out" "TooManyAssignmentsError" "up.sh explicit GPU exit 4 error message"
    calls="$(grep -c " assign " "$sb/logs/helper.log" 2>/dev/null || echo 0)"
    assert_eq "$calls" "1" "up.sh explicit GPU must not loop after exit code 4"
}

# ==============================================================================
# 6. tune.sh HTTP 500 reporting test
# ==============================================================================

test_tune_reports_http_500_quickly() {
    local sb
    sb="$(make_sandbox tune-500)"

    cat > "$sb/bin/ssh" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
    [[ "$a" == "-O" ]] && exit 0
done
cmd="${@: -1}"
if [[ "$cmd" == "python3 -" ]]; then
    cat >/dev/null
    exit 1
fi
if [[ "$cmd" == *"/health"* ]]; then
    exit 0
fi
if [[ "$cmd" == *"/api/native/operations"* ]]; then
    cat >/dev/null
    printf '{"error":"engine unavailable"}\n500\n'
    exit 0
fi
exit 0
EOF
    chmod +x "$sb/bin/ssh"

    local t0 t1 elapsed out rc=0
    t0="$(date +%s)"
    out="$(clean_env_bash "$sb" MODEL=IQ3_S bash "$sb/repo/tune.sh" quick coding work </dev/null 2>&1)" || rc=$?
    t1="$(date +%s)"
    elapsed=$((t1 - t0))

    if (( rc == 0 )); then
        fail_msg "tune.sh should exit non-zero on HTTP 500"
    fi
    if (( elapsed > 4 )); then
        fail_msg "tune.sh took ${elapsed}s on HTTP 500 (expected fast failure without polling)"
    fi
    assert_contains "$out" "HTTP 500" "tune.sh reports HTTP 500 status"
    assert_contains "$out" "engine unavailable" "tune.sh surfaces HTTP 500 body"
}

# ==============================================================================
# Run all tests
# ==============================================================================

run_test "common.sh: CRLF config.env parsing" test_common_crlf_config
run_test "common.sh: _CALLER_ENV empty-string override beats config.local.env" test_common_caller_env_empty_string_override
run_test "common.sh: recommended_model_slot & resolve_auto_model across GPUs" test_common_model_slot_and_auto_resolution
run_test "common.sh: ensure_master FD-9 non-inheritance" test_common_ensure_master_fd9_non_inheritance
run_test "common.sh: remote_healthy/local_healthy & emit_ui_state gating" test_common_health_checks_and_ui_state_gating
run_test "common.sh: workload-monitor.lock mutual exclusion" test_common_workload_monitor_lock_exclusion
run_test "status.sh --json: exact 15 keys/types and call budget" test_status_json_schema_and_call_budget
run_test "down.sh: stale SYNCING exits immediately and invokes colab stop" test_down_stale_syncing_exits_immediately_and_stops
run_test "ssh.sh: forwards -t, -L, -o, -p, -- cleanly" test_ssh_flag_forwarding
run_test "up.sh: ^ASSIGNED_GPU= parsing and non-TTY check_gpu guard" test_up_assigned_gpu_parsing_and_nontty_check_gpu_guard
run_test "up.sh: exit code 4 stops immediately without looping" test_up_exit_code_4_stops_without_looping
run_test "tune.sh: reports HTTP 500 quickly without swallowing it" test_tune_reports_http_500_quickly

printf '\nSummary: %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
(( FAIL_COUNT == 0 ))
