#!/usr/bin/env bash
# ==============================================================================
# Allocate a Google Colab GPU Runtime, Mount Drive, Start Strata & Open Tunnel
# ==============================================================================
# Safe to re-run if interrupted: completed steps are automatically reused.
source "$(dirname "$0")/lib/common.sh"

gpu_spec_desc() {
    case "$1" in
        G4)   echo "RTX PRO 6000 Blackwell: 98 GB VRAM / 176 GB RAM" ;;
        H100) echo "80 GB VRAM / ~167 GB RAM" ;;
        A100) echo "40-80 GB VRAM / ~83-167 GB RAM" ;;
        L4)   echo "23 GB VRAM / 52 GB RAM" ;;
        T4)   echo "15 GB VRAM / 12.7-51 GB RAM" ;;
        *)    echo "Colab GPU" ;;
    esac
}

expect_gpu_regex_for() {
    case "$1" in
        G4) echo "G4|RTX PRO 6000|Blackwell" ;;
        *)  echo "$1" ;;
    esac
}

ELIGIBLE_GPUS=()
INELIGIBLE_GPUS=""

fetch_colab_info() {
    local py line
    py="$(colab_python)" || { colab usage || true; return 0; }
    while IFS= read -r line; do
        case "$line" in
            ELIGIBLE_GPUS=*)
                read -r -a ELIGIBLE_GPUS <<<"${line#ELIGIBLE_GPUS=}"
                ;;
            INELIGIBLE_GPUS=*)
                INELIGIBLE_GPUS="${line#INELIGIBLE_GPUS=}"
                ;;
            *)
                echo "$line"
                ;;
        esac
    done < <("$py" "$ROOT/lib/colab-helper.py" info)
    if (( ${#ELIGIBLE_GPUS[@]} == 0 )); then
        ELIGIBLE_GPUS=(G4 H100 A100 L4 T4)
    fi
}

select_and_create_runtime() {
    local py
    py="$(colab_python)" || die "colab python not found"

    # 1. Check for an existing or orphaned server-side runtime
    local adopt_out=""
    if adopt_out="$("$py" "$ROOT/lib/colab-helper.py" adopt "$COLAB_SESSION" 2>/dev/null)"; then
        local info="${adopt_out#*=}"
        local s_name s_gpu s_shape s_ep
        IFS=':' read -r s_name s_gpu s_shape s_ep <<<"$info"
        log "$(msg runtime_exists_detail "$s_name" "$s_gpu" "$s_shape" "$s_ep")"
        if [[ "${ASK_GPU:-1}" == 1 && -t 0 ]]; then
            local reuse_ans=""
            read -r -p "$(msg runtime_reuse_prompt)" reuse_ans || reuse_ans="y"
            if [[ -z "$reuse_ans" || "$reuse_ans" =~ ^[yY] ]]; then
                GPU="$s_gpu"
                EXPECT_GPU_REGEX="$(expect_gpu_regex_for "$s_gpu")"
                return 0
            fi
            log "$(msg stopping_runtime "$COLAB_SESSION")"
            stop_master
            colab stop -s "$COLAB_SESSION" || true
        else
            GPU="$s_gpu"
            EXPECT_GPU_REGEX="$(expect_gpu_regex_for "$s_gpu")"
            return 0
        fi
    fi

    # 2. Allocate a new runtime (with AUTO waterfall, interactive GPU selector & capacity fallback)
    local -A no_cap=()
    local need_prompt="${ASK_GPU:-1}"
    local default_gpu="${GPU^^}"
    local all_label="" _g
    for _g in "${ELIGIBLE_GPUS[@]}"; do
        all_label+="${all_label:+ -> }$_g"
    done

    while true; do
        if [[ "$default_gpu" != "AUTO" && -n "${no_cap[$default_gpu]:-}" ]]; then
            local g
            for g in "${ELIGIBLE_GPUS[@]}"; do
                if [[ -z "${no_cap[$g]:-}" ]]; then
                    default_gpu="$g"
                    break
                fi
            done
        fi

        if [[ "$need_prompt" == 1 && -t 0 ]]; then
            echo
            log "$(msg gpu_menu_header)"
            local auto_tag=""
            [[ "$default_gpu" == "AUTO" ]] && auto_tag="$(msg gpu_menu_default_tag)"
            printf "    0) AUTO  (%s)%s\n" "$(msg gpu_menu_auto_option "$all_label")" "$auto_tag"
            local idx=1 g tag desc
            for g in "${ELIGIBLE_GPUS[@]}"; do
                desc="$(gpu_spec_desc "$g")"
                tag=""
                [[ "$g" == "$default_gpu" ]] && tag+="$(msg gpu_menu_default_tag)"
                [[ -n "${no_cap[$g]:-}" ]] && tag+="$(msg gpu_menu_nocap_tag)"
                printf "    %d) %-5s (%s)%s\n" "$idx" "$g" "$desc" "$tag"
                idx=$((idx + 1))
            done
            if [[ -n "$INELIGIBLE_GPUS" ]]; then
                echo "$(msg gpu_menu_ineligible "$INELIGIBLE_GPUS")"
            fi
            echo
            local choice=""
            read -r -p "$(msg gpu_select_prompt "$default_gpu")" choice || choice=""
            choice="${choice//[[:space:]]/}"
            if [[ -z "$choice" ]]; then
                GPU="$default_gpu"
            elif [[ "$choice" == "0" || "${choice^^}" == "AUTO" ]]; then
                GPU="AUTO"
            elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ELIGIBLE_GPUS[@]} )); then
                GPU="${ELIGIBLE_GPUS[$((choice - 1))]}"
            else
                GPU="${choice^^}"
            fi
        else
            GPU="$default_gpu"
        fi

        stop_master

        if [[ "$GPU" == "AUTO" ]]; then
            local -a candidates=()
            local g
            for g in "${ELIGIBLE_GPUS[@]}"; do
                [[ -z "${no_cap[$g]:-}" ]] && candidates+=("$g")
            done
            if (( ${#candidates[@]} == 0 )); then
                no_cap=()
                candidates=("${ELIGIBLE_GPUS[@]}")
            fi
            local candidates_csv
            candidates_csv="$(IFS=,; echo "${candidates[*]}")"
            log "$(msg gpu_auto_starting "$candidates_csv")"

            local assign_line="" assigned_line="" helper_pid="" rc=0
            exec 3< <("$py" "$ROOT/lib/colab-helper.py" auto-assign "$COLAB_SESSION" "$candidates_csv" "${HIGH_MEM:-0}")
            helper_pid=$!
            while IFS= read -r assign_line <&3; do
                case "$assign_line" in
                    ASSIGNED_GPU=*)
                        assigned_line="${assign_line#ASSIGNED_GPU=}"
                        ;;
                    \[STRATA_STATE:*)
                        printf '%s\n' "$assign_line"
                        ;;
                esac
            done
            exec 3<&-
            wait "$helper_pid" || rc=$?

            if (( rc == 0 )); then
                local assigned_gpu="" assigned_shape="STANDARD"
                if [[ -n "$assigned_line" ]]; then
                    assigned_gpu="${assigned_line%%:*}"
                    if [[ "$assigned_line" == *:* ]]; then
                        assigned_shape="${assigned_line#*:}"
                    fi
                fi
                [[ -n "$assigned_gpu" ]] && GPU="$assigned_gpu"
                log "$(msg gpu_auto_selected "$GPU" "${assigned_shape:-STANDARD}")"
                EXPECT_GPU_REGEX="$(expect_gpu_regex_for "$GPU")"
                return 0
            elif (( rc == 4 )); then
                die "$(msg gpu_too_many_assignments)"
            fi
            warn "$(msg gpu_auto_all_failed "$candidates_csv")"
            for g in "${candidates[@]}"; do no_cap[$g]=1; done
            need_prompt=1
            [[ -t 0 ]] || die "$(msg gpu_aborted)"
            continue
        fi

        local hm_flag=""
        if [[ "$HIGH_MEM" == 1 && "$GPU" != "G4" && "$GPU" != "H100" && "$GPU" != "L4" ]]; then
            hm_flag=" --high-mem"
        fi
        emit_ui_state "probing:$GPU"
        log "$(msg runtime_creating "colab new -s $COLAB_SESSION --gpu $GPU$hm_flag")"

        local rc=0
        "$py" "$ROOT/lib/colab-helper.py" assign "$COLAB_SESSION" "$GPU" "${HIGH_MEM:-0}" || rc=$?
        if (( rc == 0 )); then
            EXPECT_GPU_REGEX="$(expect_gpu_regex_for "$GPU")"
            return 0
        elif (( rc == 4 )); then
            die "$(msg gpu_too_many_assignments)"
        elif (( rc == 2 )); then
            warn "$(msg gpu_no_capacity "$GPU")"
            no_cap[$GPU]=1
            need_prompt=1
            [[ -t 0 ]] || die "$(msg gpu_aborted)"
        elif (( rc == 3 )); then
            warn "$(msg gpu_not_entitled "$GPU")"
            no_cap[$GPU]=1
            need_prompt=1
            [[ -t 0 ]] || die "$(msg gpu_aborted)"
        else
            die "$(msg gpu_aborted)"
        fi
    done
}

ensure_drive_mounted() {
    [[ "${USE_DRIVE:-1}" == 1 ]] || return 0
    local q_mount
    q_mount="$(printf '%q' "$DRIVE_MOUNT/MyDrive")"
    if rssh "[[ -d $q_mount ]]" 2>/dev/null; then
        log "$(msg drive_already_mounted "$DRIVE_DATA_DIR")"
        return 0
    fi
    log "$(msg drive_mounting "$DRIVE_MOUNT")"
    local dm_rc=0
    if [[ ! -t 0 ]] && command -v setsid >/dev/null 2>&1; then
        # Detach controlling TTY so colab drivemount reads Enter from piped stdin when hosted by the UI.
        setsid -w colab drivemount -s "$COLAB_SESSION" "$DRIVE_MOUNT" || dm_rc=$?
    else
        colab drivemount -s "$COLAB_SESSION" "$DRIVE_MOUNT" || dm_rc=$?
    fi
    if (( dm_rc != 0 )); then
        warn "$(msg drive_mount_failed)"
        USE_DRIVE=0
    fi
}

select_model() {
    [[ -z "$MODEL_REPO" ]] || return 0

    if [[ "${ASK_MODEL:-1}" != 1 || ! -t 0 ]]; then
        resolve_auto_model "$GPU"
        return 0
    fi

    probe_vm_memory_gb
    local def_num
    def_num="$(recommended_model_slot "$GPU")"

    # Detect models already cached in Google Drive
    local drive_files=""
    if [[ "${USE_DRIVE:-1}" == 1 && "${DRIVE_MODEL_CACHE:-0}" == 1 ]]; then
        local q_dd
        q_dd="$(printf '%q' "$DRIVE_DATA_DIR")"
        drive_files="$(rssh "find $q_dd -name '*.gguf' 2>/dev/null" 2>/dev/null || true)"
    fi

    is_model_cached() {
        [[ -n "$drive_files" ]] && grep -qi "$1" <<<"$drive_files"
    }

    local -a m_keys=("UD-Q4_K_XL" "IQ2_XS" "Q2_0" "IQ1_M" "IQ3_S" "NVFP4")
    local -a m_cached=(0 0 0 0 0 0)
    local i
    for i in 0 1 2 3 4 5; do
        if is_model_cached "${m_keys[$i]}"; then
            m_cached[$i]=1
        fi
    done
    if (( m_cached[def_num - 1] == 0 )); then
        for i in 0 1 2 3 4 5; do
            if (( m_cached[i] == 1 )); then
                def_num=$((i + 1))
                break
            fi
        done
    fi

    model_tags() {
        local idx="$1" out=""
        (( idx == def_num )) && out+="$(msg gpu_menu_default_tag)"
        (( m_cached[idx - 1] == 1 )) && out+="$(msg model_cached_tag)"
        printf '%s' "$out"
    }

    echo
    log "$(msg model_menu_header "$GPU" "$CONTEXT")"
    printf "    1) Qwen3.6-35B-A3B  [UD-Q4_K_XL]  (22.9 GB download, ~4-5 min start, fits L4/T4)%s\n" "$(model_tags 1)"
    printf "    2) Qwen3.8-Flash    [IQ2_XS]      (~68 GB download, 35.5 GB RAM, recommended for L4 52GB)%s\n" "$(model_tags 2)"
    printf "    3) Qwen3.8-Flash    [Q2_0]        (~66 GB download, 34.0 GB RAM, fastest full Qwen3.8)%s\n" "$(model_tags 3)"
    printf "    4) Qwen3.8-Coder    [IQ1_M]       (~36 GB download, 23.0 GB RAM, coding specialist)%s\n" "$(model_tags 4)"
    printf "    5) Qwen3.8-Flash    [IQ3_S]       (~84 GB download, 50.0 GB RAM, best for A100/H100)%s\n" "$(model_tags 5)"
    printf "    6) Qwen3.8-Flash    [NVFP4]       (~63 GB download, native Blackwell FP4, best for G4 98GB)%s\n" "$(model_tags 6)"
    echo

    while true; do
        local ans=""
        if ! read -r -p "$(msg model_select_prompt "$def_num")" ans; then
            ans="$def_num"
        fi
        ans="${ans//[[:space:]]/}"
        [[ -z "$ans" ]] && ans="$def_num"

        case "$ans" in
            1) MODEL_FAMILY="qwen36"; MODEL="UD-Q4_K_XL"; break ;;
            2) MODEL_FAMILY="";       MODEL="IQ2_XS";     break ;;
            3) MODEL_FAMILY="";       MODEL="Q2_0";       break ;;
            4) MODEL_FAMILY="coder";  MODEL="IQ1_M";      break ;;
            5) MODEL_FAMILY="";       MODEL="IQ3_S";      break ;;
            6) MODEL_FAMILY="nvfp4";  MODEL="NVFP4";      break ;;
            *) warn "$(msg model_invalid_choice "$ans" 6)" ;;
        esac
    done
}

check_gpu() {
    local gpu="" attempt
    for attempt in 1 2 3; do
        gpu="$(rssh "nvidia-smi --query-gpu=name,memory.total --format=csv,noheader" 2>/dev/null | head -n 1 || true)"
        [[ -n "${gpu//[[:space:]]/}" ]] && break
        sleep 3
    done
    log "$(msg gpu_line "${gpu:-$(msg gpu_unknown)}")"
    [[ -n "$gpu" && "$gpu" =~ $EXPECT_GPU_REGEX ]] && return 0

    warn "$(msg gpu_mismatch "$EXPECT_GPU_REGEX")"
    local ans="n"
    case "$ON_GPU_MISMATCH" in
        continue) return 0 ;;
        stop) ans=n ;;
        *)
            if [[ -t 0 ]]; then
                read -r -p "$(msg gpu_continue_prompt)" ans || ans=n
            else
                warn "Non-interactive session detected; aborting on GPU mismatch (set ON_GPU_MISMATCH=continue to override)."
                ans=n
            fi
            ;;
    esac
    [[ "$ans" =~ ^[yY] ]] && return 0

    log "$(msg stopping_to_save)"
    stop_master
    colab stop -s "$COLAB_SESSION" || true
    die "$(msg gpu_aborted)"
}

main() {
    require_cmds colab ssh curl ss
    reset_workload_log

    log "$(msg units_left)"
    fetch_colab_info

    # 1. Select or create Colab GPU runtime (with interactive capacity fallback)
    select_and_create_runtime

    # 2. Verify SSH connectivity and allocated GPU model
    log "$(msg ssh_connecting)"
    wait_ssh
    check_gpu

    # 3. Mount Google Drive for persistent presets/configs (and optional model cache)
    ensure_drive_mounted

    # 4. Select Strata model matched to GPU memory and Drive cache status
    select_model

    # 5. Provision and start Strata (Desktop UI or CLI server) inside tmux on the VM
    emit_ui_state "starting"
    log "$(msg preparing)"
    remote_start 0

    # 6. Wait for Strata to become healthy
    log "$(msg waiting_start)"
    wait_healthy
    log "$(msg started)"

    # 7. Open local SSH port-forwarding tunnel and launch browser
    run_tunnel_foreground
}

main "$@"
