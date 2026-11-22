#!/usr/bin/env python3
"""Helper using google-colab-cli's internal client to query eligible GPUs and allocate runtimes cleanly."""

import json
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


def cmd_info() -> int:
    """Authenticate (if needed), print compute unit usage, and print eligible GPUs."""
    state.client._issue_request(
        f"{state.client.colab_domain}/tun/m/ccu-info",
        schema=None,
    )
    resp = state.client.session.get(
        f"{state.client.colab_domain}/tun/m/ccu-info",
        headers={"Accept": "application/json", "X-Colab-Client-Agent": "colab-cli"},
        params={"authuser": "0"},
    )
    text = resp.text
    if text.startswith(")]}'\n"):
        text = text[5:]
    data = json.loads(text)

    balance = float(data.get("currentBalance", 0.0))
    rate = float(data.get("consumptionRateHourly", 0.0))
    count = int(data.get("assignmentsCount", 0))
    eligible = data.get("eligibleGpus") or []
    ineligible = data.get("ineligibleGpus") or []

    order = ["G4", "H100", "A100", "L4", "T4"]
    eligible_sorted = [g for g in order if g in eligible] + [
        g for g in eligible if g not in order
    ]

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


def cmd_assign(name: str, gpu_str: str, high_mem_str: str) -> int:
    """Attempt to allocate a single GPU runtime without long retry loops or raw tracebacks.

    Exit codes:
      0 - Allocated and saved to session store
      2 - No capacity available right now (503 / 502 / 504 / 412 / timeout)
      3 - Account not eligible / quota rejected (400)
      1 - Other error
    """
    accelerator = Accelerator(gpu_str.upper())
    variant = Variant.GPU
    high_mem = (high_mem_str == "1") and (accelerator not in SINGLE_SHAPE_GPUS)
    shape = resolve_assign_shape(accelerator, high_mem=high_mem)

    # Check if an active server assignment already exists (e.g., created via Colab MCP or browser)
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
            return 0

    nbh = uuid.uuid4()

    # Cold-booting A100/G4 VMs often takes 40-45s, while Colab's HTTP proxy cuts off POST /tun/m/assign at 30s with 503.
    # Doing 1 retry with the SAME notebook_hash (nbh) after 8s claims the VM once it finishes booting.
    res = None
    for attempt in range(2):
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
        except TooManyAssignmentsError:
            return 2
        except Exception as e:
            status = get_status_code(e) if isinstance(e, ColabRequestError) else None
            if status in (502, 503, 504) or "Timeout" in type(e).__name__:
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
                if attempt == 0:
                    continue
                return 2
            elif status == 412:
                return 2
            elif status == 400:
                return 3
            else:
                print(f"[colab] Error: {e}", file=sys.stderr)
                return 1

    if res is None:
        return 2

    if isinstance(res, PostAssignmentResponse):
        token = res.runtime_proxy_info.token
        url = res.runtime_proxy_info.url
        endpoint = res.endpoint
        expires_at = res.runtime_proxy_info.expires_at()
    else:
        token = (
            res.runtime_proxy_info.token
            if hasattr(res, "runtime_proxy_info")
            else getattr(res, "runtime_proxy_token", "")
        )
        url = res.runtime_proxy_info.url if hasattr(res, "runtime_proxy_info") else ""
        endpoint = res.endpoint
        expires_at = (
            res.runtime_proxy_info.expires_at()
            if hasattr(res, "runtime_proxy_info")
            else None
        )

    machine_shape = (
        Shape.HIGH_RAM.name if shape == Shape.HIGH_RAM else Shape.STANDARD.name
    )
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


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: colab-helper.py <info|adopt|assign> ...", file=sys.stderr)
        return 1
    cmd = sys.argv[1]
    if cmd == "info":
        return cmd_info()
    if cmd == "adopt":
        return cmd_adopt_existing(sys.argv[2])
    if cmd == "assign":
        return cmd_assign(sys.argv[2], sys.argv[3], sys.argv[4])
    return 1


if __name__ == "__main__":
    sys.exit(main())
