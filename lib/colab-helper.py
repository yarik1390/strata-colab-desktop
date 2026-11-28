#!/usr/bin/env python3
"""Helper using google-colab-cli's internal client to query eligible GPUs and allocate runtimes cleanly."""

import contextlib
import json
import os
import sys
import time
import uuid

from colab_cli.client import (
    Accelerator,
    Assignment,
    ColabRequestError,
    PostAssignmentResponse,
    Shape,
    TooManyAssignmentsError,
    Variant,
    resolve_assign_shape,
)
from colab_cli.common import state
from colab_cli.state import SessionState
from colab_cli.utils import get_status_code


def cmd_info(as_json: bool = False, session_name: str | None = None) -> int:
    """Authenticate (if needed), print compute unit usage, and print eligible GPUs."""
    try:
        data = state.client._issue_request(
            f"{state.client.colab_domain}/tun/m/ccu-info",
            schema=dict,
        )
    except Exception as e:
        print(f"[colab] Failed to fetch ccu-info: {_format_error(e)}", file=sys.stderr)
        return 1

    if not isinstance(data, dict):
        print("[colab] Empty or invalid ccu-info response.", file=sys.stderr)
        return 1

    balance = float(data.get("currentBalance", 0.0))
    rate = float(data.get("consumptionRateHourly", 0.0))
    count = int(data.get("assignmentsCount", 0))
    eligible = data.get("eligibleGpus") or []
    ineligible = data.get("ineligibleGpus") or []

    order = ["G4", "H100", "A100", "L4", "T4"]
    eligible_sorted = [g for g in order if g in eligible] + [
        g for g in eligible if g not in order
    ]

    if as_json:
        runtime_active = False
        if session_name:
            try:
                has_local = False
                getter = getattr(state.store, "get", None)
                if callable(getter):
                    has_local = getter(session_name) is not None
                if count > 0 or has_local:
                    with contextlib.redirect_stdout(sys.stderr):
                        sessions, assignments = state.sync_sessions()
                        if session_name in sessions:
                            runtime_active = True
                        elif assignments:
                            a = assignments[0]
                            _save_session(
                                name=session_name,
                                endpoint=a.endpoint,
                                token=a.runtime_proxy_info.token,
                                url=a.runtime_proxy_info.url,
                                expires_at=a.runtime_proxy_info.expires_at(),
                                variant=a.variant.name,
                                accelerator=a.accelerator.value,
                                machine_shape=a.machine_shape.name,
                            )
                            runtime_active = True
            except Exception as e:
                print(f"[colab] Session sync warning: {_format_error(e)}", file=sys.stderr)
                runtime_active = count > 0
        payload = {
            "cu_balance": round(balance, 4),
            "cu_rate": round(rate, 4),
            "assignments_count": count,
            "eligible_gpus": eligible_sorted,
            "ineligible_gpus": list(ineligible),
            "runtime_active": runtime_active,
        }
        print(json.dumps(payload))
        return 0

    print(f"    Current balance: {balance:.2f} compute units")
    print(f"    Usage rate: {rate:.2f}/hr")
    print(f"    Active assignments: {count}")
    print(f"ELIGIBLE_GPUS={' '.join(eligible_sorted)}")
    print(f"INELIGIBLE_GPUS={' '.join(ineligible)}")
    return 0


def _save_session(
    name: str,
    endpoint: str,
    token: str,
    url: str,
    expires_at,
    variant: str,
    accelerator: str,
    machine_shape: str,
) -> None:
    s = SessionState(
        name=name,
        token=token,
        url=url,
        endpoint=endpoint,
        token_expires_at=expires_at,
        variant=variant,
        accelerator=accelerator,
        machine_shape=machine_shape,
    )
    state.store.add(s)
    state.history.log_event(
        name,
        "session_created",
        {
            "endpoint": endpoint,
            "variant": variant,
            "accelerator": accelerator,
            "machine_shape": machine_shape,
        },
    )


def cmd_adopt_existing(name: str) -> int:
    """If an orphaned server assignment exists and no local session `name` is saved, adopt it."""
    sessions, assignments = state.sync_sessions()
    if name in sessions:
        s = sessions[name]
        print(f"EXISTING_SESSION={s.name}:{s.accelerator}:{s.machine_shape}:{s.endpoint}")
        return 0
    if assignments:
        a = assignments[0]
        _save_session(
            name=name,
            endpoint=a.endpoint,
            token=a.runtime_proxy_info.token,
            url=a.runtime_proxy_info.url,
            expires_at=a.runtime_proxy_info.expires_at(),
            variant=a.variant.name,
            accelerator=a.accelerator.value,
            machine_shape=a.machine_shape.name,
        )
        print(
            f"ADOPTED_SESSION={name}:{a.accelerator.value}:{a.machine_shape.name}:{a.endpoint}"
        )
        return 0
    return 1


# Only A100 and T4 support shape=hm on Google Colab; G4, H100, and L4 only exist in STANDARD shape
# (where G4 already has 98 GB VRAM + 176 GB RAM, H100 has 80 GB VRAM + 167 GB RAM, L4 has 23 GB VRAM + 52 GB RAM).
SINGLE_SHAPE_GPUS = {Accelerator.G4, Accelerator.H100, Accelerator.L4}


def _shape_label(shape: object) -> str:
    """Return a readable shape name even when resolve_assign_shape returns None (STANDARD)."""
    return Shape.HIGH_RAM.name if shape == Shape.HIGH_RAM else Shape.STANDARD.name


def _format_error(e: Exception) -> str:
    """Format an API or transport exception into a concise, token-free diagnostic line."""
    status = get_status_code(e) if isinstance(e, ColabRequestError) else None
    detail = " ".join(str(e).split())
    if len(detail) > 160:
        detail = detail[:157] + "..."
    if status is not None:
        return f"HTTP {status} ({type(e).__name__}): {detail}"
    return f"{type(e).__name__}: {detail}"


def _extract_proxy_fields(res: object) -> tuple[str, str, str, object]:
    """Extract (endpoint, token, url, expires_at) from an assignment response."""
    if isinstance(res, PostAssignmentResponse):
        return (
            res.endpoint,
            res.runtime_proxy_info.token,
            res.runtime_proxy_info.url,
            res.runtime_proxy_info.expires_at(),
        )
    has_proxy = hasattr(res, "runtime_proxy_info")
    return (
        res.endpoint,
        res.runtime_proxy_info.token
        if has_proxy
        else getattr(res, "runtime_proxy_token", ""),
        res.runtime_proxy_info.url if has_proxy else "",
        res.runtime_proxy_info.expires_at() if has_proxy else None,
    )


def _adopt_matching_assignment(
    name: str, accelerator: Accelerator
) -> tuple[bool, str]:
    """Adopt an active server-side assignment matching accelerator if one already exists."""
    _, existing_assignments = state.sync_sessions()
    for a in existing_assignments:
        if a.accelerator == accelerator:
            _save_session(
                name=name,
                endpoint=a.endpoint,
                token=a.runtime_proxy_info.token,
                url=a.runtime_proxy_info.url,
                expires_at=a.runtime_proxy_info.expires_at(),
                variant=a.variant.name,
                accelerator=a.accelerator.value,
                machine_shape=a.machine_shape.name,
            )
            return True, a.machine_shape.name
    return False, ""


def _assign_single_shape(name: str, accelerator: Accelerator, shape: Shape) -> int:
    """Attempt one GPU + Shape allocation with fast failure on pool exhaustion.

    Only waits and retries once when a 502/503/504/Timeout occurred after >=20s
    (characteristic of cold-booting VMs past Colab's 30s HTTP proxy cutoff).
    Fast capacity refusals (412 or <20s 503) return code 2 immediately.
    TooManyAssignmentsError returns code 4 immediately.
    """
    variant = Variant.GPU
    nbh = uuid.uuid4()
    res = None

    for attempt in range(2):
        t0 = time.monotonic()
        try:
            assignment = state.client._get_assignment(
                nbh, variant=variant, accelerator=accelerator, shape=shape
            )
            if isinstance(assignment, Assignment):
                res = assignment
                break
            res = state.client._post_assignment(
                nbh,
                assignment.token,
                variant=variant,
                accelerator=accelerator,
                shape=shape,
            )
            break
        except TooManyAssignmentsError as e:
            print(
                f"[colab] {accelerator.value} ({_shape_label(shape)}): {_format_error(e)}",
                file=sys.stderr,
            )
            return 4
        except Exception as e:
            elapsed = time.monotonic() - t0
            status = get_status_code(e) if isinstance(e, ColabRequestError) else None
            print(
                f"[colab] {accelerator.value} ({_shape_label(shape)}) failed in {elapsed:.1f}s: {_format_error(e)}",
                file=sys.stderr,
            )
            if status == 412:
                return 2
            if status == 400:
                return 3
            if status in (502, 503, 504) or "Timeout" in type(e).__name__:
                if elapsed < 20.0:
                    return 2
                time.sleep(8)
                try:
                    check = state.client._get_assignment(
                        nbh, variant=variant, accelerator=accelerator, shape=shape
                    )
                    if isinstance(check, Assignment):
                        res = check
                        break
                except Exception:
                    pass
                adopted, _ = _adopt_matching_assignment(name, accelerator)
                if adopted:
                    return 0
                if attempt == 0:
                    continue
                return 2
            return 1

    if res is None:
        return 2

    endpoint, token, url, expires_at = _extract_proxy_fields(res)
    machine_shape = _shape_label(shape)
    _save_session(
        name=name,
        endpoint=endpoint,
        token=token,
        url=url,
        expires_at=expires_at,
        variant=variant.value,
        accelerator=accelerator.value,
        machine_shape=machine_shape,
    )
    return 0


def _assign_gpu_with_fallback(
    name: str, gpu_str: str, high_mem_str: str
) -> tuple[int, str]:
    """Assign a GPU, falling back from HIGH_RAM to STANDARD shape when supported."""
    try:
        accelerator = Accelerator(gpu_str.upper())
    except ValueError as e:
        print(f"[colab] Invalid GPU {gpu_str!r}: {e}", file=sys.stderr)
        return 1, ""

    adopted, adopted_shape = _adopt_matching_assignment(name, accelerator)
    if adopted:
        return 0, adopted_shape

    high_mem = (high_mem_str == "1") and (accelerator not in SINGLE_SHAPE_GPUS)
    primary = resolve_assign_shape(accelerator, high_mem=high_mem)
    fallback = resolve_assign_shape(accelerator, high_mem=False)
    shapes = [primary] if primary == fallback else [primary, fallback]

    for idx, shape in enumerate(shapes):
        if idx > 0:
            print(
                f"[colab] {accelerator.value} {_shape_label(shapes[idx - 1])} unavailable; falling back to {_shape_label(shape)} shape...",
                file=sys.stderr,
            )
        rc = _assign_single_shape(name, accelerator, shape)
        if rc == 0:
            return 0, _shape_label(shape)
        if rc in (1, 3, 4):
            return rc, ""

    return 2, ""


def cmd_assign(name: str, gpu_str: str, high_mem_str: str) -> int:
    """Attempt to allocate a single GPU runtime (with HIGH_RAM -> STANDARD fallback).

    Exit codes:
      0 - Allocated and saved to session store
      2 - No capacity available right now (503 / 502 / 504 / 412 / timeout)
      3 - Account not eligible / quota rejected (400)
      4 - Too many concurrent assignments (TooManyAssignmentsError)
      1 - Other error
    """
    rc, _ = _assign_gpu_with_fallback(name, gpu_str, high_mem_str)
    return rc


def cmd_auto_assign(name: str, gpus_csv: str, high_mem_str: str) -> int:
    """Try candidate GPUs in preference order until one succeeds.

    Prints ASSIGNED_GPU=<GPU>:<SHAPE> to stdout on success.
    Stops immediately with exit code 4 on TooManyAssignmentsError.
    """
    gpus = [
        g.strip().upper()
        for g in gpus_csv.replace(" ", ",").split(",")
        if g.strip()
    ]
    if not gpus:
        gpus = ["G4", "H100", "A100", "L4", "T4"]

    # Prefer adopting an already-active assignment matching any candidate in priority order.
    for gpu_str in gpus:
        try:
            acc = Accelerator(gpu_str)
        except ValueError:
            continue
        adopted, adopted_shape = _adopt_matching_assignment(name, acc)
        if adopted:
            print(f"ASSIGNED_GPU={gpu_str}:{adopted_shape}", flush=True)
            return 0

    ui_host = os.environ.get("STRATA_UI_HOST") == "1"
    saw_nocap = False
    saw_not_entitled = False
    for gpu_str in gpus:
        if ui_host:
            print(f"[STRATA_STATE:probing:{gpu_str}]", flush=True)
        print(f"[colab] Trying {gpu_str}...", file=sys.stderr, flush=True)
        rc, chosen_shape = _assign_gpu_with_fallback(name, gpu_str, high_mem_str)
        if rc == 0:
            print(f"ASSIGNED_GPU={gpu_str}:{chosen_shape}", flush=True)
            return 0
        if rc == 4:
            return 4
        if rc == 2:
            saw_nocap = True
        elif rc == 3:
            saw_not_entitled = True

    if saw_nocap:
        return 2
    if saw_not_entitled:
        return 3
    return 1


def _usage() -> int:
    print(
        "Usage: colab-helper.py <info [--json] [--session NAME] | adopt NAME | assign NAME GPU HIGH_MEM | auto-assign NAME GPUS_CSV HIGH_MEM>",
        file=sys.stderr,
    )
    return 1


def main() -> int:
    if len(sys.argv) < 2:
        return _usage()
    cmd = sys.argv[1]
    if cmd == "info":
        as_json = False
        session_name = None
        i = 2
        while i < len(sys.argv):
            arg = sys.argv[i]
            if arg == "--json":
                as_json = True
                i += 1
            elif arg == "--session":
                if i + 1 >= len(sys.argv):
                    return _usage()
                session_name = sys.argv[i + 1]
                i += 2
            else:
                return _usage()
        return cmd_info(as_json=as_json, session_name=session_name)
    if cmd == "adopt":
        if len(sys.argv) < 3:
            return _usage()
        return cmd_adopt_existing(sys.argv[2])
    if cmd == "assign":
        if len(sys.argv) < 5:
            return _usage()
        return cmd_assign(sys.argv[2], sys.argv[3], sys.argv[4])
    if cmd == "auto-assign":
        if len(sys.argv) < 5:
            return _usage()
        return cmd_auto_assign(sys.argv[2], sys.argv[3], sys.argv[4])
    return _usage()


if __name__ == "__main__":
    sys.exit(main())
