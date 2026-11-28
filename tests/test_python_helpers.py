#!/usr/bin/env python3
"""Offline unit tests for Strata Colab Desktop Python helpers.

Covers:
  1. lib/colab-helper.py (runs both WITH real google-colab-cli and WITHOUT it via sys.modules stubs)
  2. lib/colab-workload.py
  3. Embedded strata-drive-cache.py extracted in-memory from lib/remote-setup.sh

Zero external pip dependencies and zero live Google Colab calls.
"""

from __future__ import annotations

import contextlib
import datetime
import enum
import errno
import hashlib
import importlib.util
import io
import json
import os
import re
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True

REPO_ROOT = Path(__file__).resolve().parent.parent
COLAB_HELPER_PATH = REPO_ROOT / "lib" / "colab-helper.py"
COLAB_WORKLOAD_PATH = REPO_ROOT / "lib" / "colab-workload.py"
REMOTE_SETUP_PATH = REPO_ROOT / "lib" / "remote-setup.sh"


def _ensure_colab_cli_available() -> bool:
    """Install lightweight sys.modules stubs for colab_cli when not installed.

    Returns True if real colab_cli is installed, False if stubs were injected.
    """
    if importlib.util.find_spec("colab_cli") is not None:
        return True

    pkg = types.ModuleType("colab_cli")
    pkg.__path__ = []

    client_mod = types.ModuleType("colab_cli.client")

    class Accelerator(enum.Enum):
        NONE = "NONE"
        G4 = "G4"
        T4 = "T4"
        L4 = "L4"
        A100 = "A100"
        H100 = "H100"
        V5E1 = "V5E1"
        V6E1 = "V6E1"

    class Shape(enum.Enum):
        STANDARD = 0
        HIGH_RAM = 1

    class Variant(enum.Enum):
        DEFAULT = "DEFAULT"
        GPU = "GPU"
        TPU = "TPU"

    class AssignmentVariant(enum.Enum):
        DEFAULT = 0
        GPU = 1
        TPU = 2

    HIGH_MEM_ONLY_ACCELERATORS = frozenset(
        {Accelerator.V6E1, Accelerator.V5E1, Accelerator.L4}
    )

    class RuntimeProxyInfo:
        def __init__(
            self,
            *,
            token: str,
            tokenExpiresInSeconds: int = 3600,
            url: str,
        ) -> None:
            self.token = token
            self.token_expires_in_seconds = tokenExpiresInSeconds
            self.url = url

        def expires_at(self) -> datetime.datetime:
            return datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(
                seconds=self.token_expires_in_seconds
            )

    class Assignment:
        def __init__(self, *, endpoint: str, runtimeProxyInfo: RuntimeProxyInfo) -> None:
            self.endpoint = endpoint
            self.runtime_proxy_info = runtimeProxyInfo

    class PostAssignmentResponse:
        def __init__(
            self,
            *,
            accelerator: Accelerator,
            endpoint: str,
            runtimeProxyInfo: RuntimeProxyInfo,
            variant: AssignmentVariant,
        ) -> None:
            self.accelerator = accelerator
            self.endpoint = endpoint
            self.runtime_proxy_info = runtimeProxyInfo
            self.variant = variant

    class ColabRequestError(Exception):
        def __init__(self, message, request, response, response_body=None) -> None:
            super().__init__(message)
            self.request = request
            self.response = response
            self.response_body = response_body

    class TooManyAssignmentsError(Exception):
        pass

    def resolve_assign_shape(
        accelerator: Accelerator | None, *, high_mem: bool = False
    ) -> Shape | None:
        if not high_mem:
            return None
        if accelerator in HIGH_MEM_ONLY_ACCELERATORS:
            return None
        return Shape.HIGH_RAM

    client_mod.Accelerator = Accelerator
    client_mod.Shape = Shape
    client_mod.Variant = Variant
    client_mod.AssignmentVariant = AssignmentVariant
    client_mod.HIGH_MEM_ONLY_ACCELERATORS = HIGH_MEM_ONLY_ACCELERATORS
    client_mod.RuntimeProxyInfo = RuntimeProxyInfo
    client_mod.Assignment = Assignment
    client_mod.PostAssignmentResponse = PostAssignmentResponse
    client_mod.ColabRequestError = ColabRequestError
    client_mod.TooManyAssignmentsError = TooManyAssignmentsError
    client_mod.resolve_assign_shape = resolve_assign_shape

    state_mod = types.ModuleType("colab_cli.state")

    class SessionState:
        def __init__(
            self,
            *,
            name: str,
            token: str,
            url: str,
            endpoint: str,
            token_expires_at=None,
            variant: str = "DEFAULT",
            accelerator: str = "NONE",
            machine_shape: str = "STANDARD",
        ) -> None:
            self.name = name
            self.token = token
            self.url = url
            self.endpoint = endpoint
            self.token_expires_at = token_expires_at
            self.variant = variant
            self.accelerator = accelerator
            self.machine_shape = machine_shape

    state_mod.SessionState = SessionState

    common_mod = types.ModuleType("colab_cli.common")
    common_mod.state = types.SimpleNamespace(
        client=None,
        store=None,
        history=None,
        sync_sessions=lambda: ({}, []),
    )

    utils_mod = types.ModuleType("colab_cli.utils")

    def get_status_code(e: Exception) -> int | None:
        if hasattr(e, "response") and e.response is not None:
            if hasattr(e.response, "status_code"):
                return e.response.status_code
        if hasattr(e, "status_code"):
            return e.status_code
        return None

    utils_mod.get_status_code = get_status_code

    sys.modules["colab_cli"] = pkg
    sys.modules["colab_cli.client"] = client_mod
    sys.modules["colab_cli.state"] = state_mod
    sys.modules["colab_cli.common"] = common_mod
    sys.modules["colab_cli.utils"] = utils_mod
    return False


USING_REAL_COLAB_CLI = _ensure_colab_cli_available()

from colab_cli.client import (  # noqa: E402
    Accelerator,
    Assignment,
    AssignmentVariant,
    ColabRequestError,
    PostAssignmentResponse,
    RuntimeProxyInfo,
    Shape,
    TooManyAssignmentsError,
    Variant,
    resolve_assign_shape,
)
from colab_cli.state import SessionState  # noqa: E402


def _load_module_from_path(name: str, path: Path) -> types.ModuleType:
    spec = importlib.util.spec_from_file_location(name, str(path))
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _load_embedded_drive_cache() -> types.ModuleType:
    text = REMOTE_SETUP_PATH.read_text(encoding="utf-8")
    match = re.search(
        r'cat > "\$DRIVE_CACHE_SCRIPT" <<\'PYEOF\'\r?\n(.*?)\r?\nPYEOF\r?\n',
        text,
        flags=re.DOTALL,
    )
    if not match:
        raise AssertionError("Could not extract embedded strata-drive-cache.py from lib/remote-setup.sh")
    src = match.group(1)
    mod = types.ModuleType("strata_drive_cache")
    mod.__file__ = "<embedded:strata-drive-cache.py>"
    code = compile(src, mod.__file__, "exec")
    exec(code, mod.__dict__)
    return mod


colab_helper = _load_module_from_path("strata_colab_helper", COLAB_HELPER_PATH)
colab_workload = _load_module_from_path("strata_colab_workload", COLAB_WORKLOAD_PATH)
drive_cache = _load_embedded_drive_cache()


def _make_proxy_info(
    token: str = "tok-test-123",
    url: str = "https://proxy.colab.example",
    ttl: int = 3600,
) -> RuntimeProxyInfo:
    return RuntimeProxyInfo(token=token, tokenExpiresInSeconds=ttl, url=url)


def _make_assignment(
    endpoint: str = "m-s-ep1",
    token: str = "tok-a",
    url: str = "https://proxy.colab.example",
) -> Assignment:
    return Assignment(endpoint=endpoint, runtimeProxyInfo=_make_proxy_info(token, url))


def _make_post_response(
    endpoint: str = "m-s-ep2",
    accelerator: Accelerator = Accelerator.A100,
    token: str = "tok-p",
    url: str = "https://proxy.colab.example",
) -> PostAssignmentResponse:
    return PostAssignmentResponse(
        accelerator=accelerator,
        endpoint=endpoint,
        runtimeProxyInfo=_make_proxy_info(token, url),
        variant=AssignmentVariant.GPU,
    )


def _make_server_assignment(
    endpoint: str = "m-s-orphan",
    accelerator: Accelerator = Accelerator.G4,
    shape: Shape = Shape.STANDARD,
    variant: Variant = Variant.GPU,
    token: str = "tok-orphan",
    url: str = "https://proxy.colab.example",
) -> types.SimpleNamespace:
    return types.SimpleNamespace(
        endpoint=endpoint,
        accelerator=accelerator,
        machine_shape=shape,
        variant=variant,
        runtime_proxy_info=_make_proxy_info(token, url),
    )


def _make_request_error(status_code: int, message: str = "request failed") -> ColabRequestError:
    return ColabRequestError(
        message,
        request=None,
        response=types.SimpleNamespace(status_code=status_code),
    )


def _make_fake_state(
    *,
    ccu_data=None,
    sync_return=None,
    local_sessions: dict[str, SessionState] | None = None,
) -> types.SimpleNamespace:
    stored: dict[str, SessionState] = dict(local_sessions or {})
    events: list[tuple] = []

    class FakeStore:
        def get(self, name: str):
            return stored.get(name)

        def add(self, session: SessionState) -> None:
            stored[session.name] = session

    class FakeHistory:
        def log_event(self, name: str, event_type: str, payload: dict) -> None:
            events.append((name, event_type, payload))

    client = mock.MagicMock()
    client.colab_domain = "https://colab.research.google.com"
    if ccu_data is not None:
        client._issue_request.return_value = ccu_data

    sync_fn = mock.MagicMock(return_value=sync_return if sync_return is not None else ({}, []))

    return types.SimpleNamespace(
        client=client,
        store=FakeStore(),
        history=FakeHistory(),
        sync_sessions=sync_fn,
        _stored=stored,
        _events=events,
    )


class TestColabHelper(unittest.TestCase):
    """Tests for lib/colab-helper.py."""

    def test_cmd_info_text_single_request_and_gpu_sort(self) -> None:
        ccu = {
            "currentBalance": 92.3456,
            "consumptionRateHourly": 1.96,
            "assignmentsCount": 1,
            "eligibleGpus": ["T4", "EXTRA_GPU", "G4", "A100", "L4"],
            "ineligibleGpus": ["H100"],
        }
        fake_state = _make_fake_state(ccu_data=ccu)
        out = io.StringIO()
        with mock.patch.object(colab_helper, "state", fake_state), contextlib.redirect_stdout(out):
            rc = colab_helper.cmd_info(as_json=False)

        self.assertEqual(rc, 0)
        fake_state.client._issue_request.assert_called_once_with(
            "https://colab.research.google.com/tun/m/ccu-info",
            schema=dict,
        )
        text = out.getvalue()
        self.assertIn("Current balance: 92.35 compute units", text)
        self.assertIn("Usage rate: 1.96/hr", text)
        self.assertIn("Active assignments: 1", text)
        self.assertIn("ELIGIBLE_GPUS=G4 A100 L4 T4 EXTRA_GPU", text)
        self.assertIn("INELIGIBLE_GPUS=H100", text)

    def test_cmd_info_json_idle_skips_sync_sessions(self) -> None:
        ccu = {
            "currentBalance": 45.12346,
            "consumptionRateHourly": 0.0,
            "assignmentsCount": 0,
            "eligibleGpus": ["L4", "G4"],
            "ineligibleGpus": ["H100"],
        }
        fake_state = _make_fake_state(ccu_data=ccu)
        out = io.StringIO()
        with mock.patch.object(colab_helper, "state", fake_state), contextlib.redirect_stdout(out):
            rc = colab_helper.cmd_info(as_json=True, session_name="strata")

        self.assertEqual(rc, 0)
        fake_state.client._issue_request.assert_called_once()
        fake_state.sync_sessions.assert_not_called()
        payload = json.loads(out.getvalue())
        self.assertEqual(
            payload,
            {
                "cu_balance": 45.1235,
                "cu_rate": 0.0,
                "assignments_count": 0,
                "eligible_gpus": ["G4", "L4"],
                "ineligible_gpus": ["H100"],
                "runtime_active": False,
            },
        )

    def test_cmd_info_json_active_adopts_orphan_and_redirects_sync_stdout(self) -> None:
        ccu = {
            "currentBalance": 50.0,
            "consumptionRateHourly": 2.5,
            "assignmentsCount": 1,
            "eligibleGpus": ["G4"],
            "ineligibleGpus": [],
        }
        orphan = _make_server_assignment(endpoint="m-s-json-orphan", accelerator=Accelerator.G4)

        def noisy_sync():
            print("noisy stdout from sync_sessions")
            return {}, [orphan]

        fake_state = _make_fake_state(ccu_data=ccu)
        fake_state.sync_sessions = mock.MagicMock(side_effect=noisy_sync)
        out, err = io.StringIO(), io.StringIO()
        with (
            mock.patch.object(colab_helper, "state", fake_state),
            contextlib.redirect_stdout(out),
            contextlib.redirect_stderr(err),
        ):
            rc = colab_helper.cmd_info(as_json=True, session_name="strata")

        self.assertEqual(rc, 0)
        fake_state.client._issue_request.assert_called_once()
        fake_state.sync_sessions.assert_called_once()
        payload = json.loads(out.getvalue())
        self.assertTrue(payload["runtime_active"])
        self.assertIn("noisy stdout from sync_sessions", err.getvalue())
        self.assertIn("strata", fake_state._stored)
        self.assertEqual(fake_state._stored["strata"].endpoint, "m-s-json-orphan")

    def test_cmd_info_http_failure_and_invalid_payload(self) -> None:
        fake_state = _make_fake_state()
        fake_state.client._issue_request.side_effect = _make_request_error(503, "Service Unavailable")
        err = io.StringIO()
        with mock.patch.object(colab_helper, "state", fake_state), contextlib.redirect_stderr(err):
            rc = colab_helper.cmd_info(as_json=True)
        self.assertEqual(rc, 1)
        self.assertIn("HTTP 503", err.getvalue())

        fake_state2 = _make_fake_state()
        fake_state2.client._issue_request.return_value = ["unexpected-list"]
        err2 = io.StringIO()
        with mock.patch.object(colab_helper, "state", fake_state2), contextlib.redirect_stderr(err2):
            rc2 = colab_helper.cmd_info(as_json=False)
        self.assertEqual(rc2, 1)
        self.assertIn("invalid ccu-info", err2.getvalue().lower())

    def test_cmd_adopt_existing_named_orphan_and_empty(self) -> None:
        existing = SessionState(
            name="strata",
            token="tok",
            url="https://proxy.example",
            endpoint="m-s-existing",
            variant="GPU",
            accelerator="A100",
            machine_shape="HIGH_RAM",
        )
        fake_state = _make_fake_state(sync_return=({"strata": existing}, []))
        out = io.StringIO()
        with mock.patch.object(colab_helper, "state", fake_state), contextlib.redirect_stdout(out):
            rc = colab_helper.cmd_adopt_existing("strata")
        self.assertEqual(rc, 0)
        self.assertEqual(out.getvalue().strip(), "EXISTING_SESSION=strata:A100:HIGH_RAM:m-s-existing")
        self.assertEqual(fake_state._events, [])

        orphan = _make_server_assignment(
            endpoint="m-s-adopted", accelerator=Accelerator.L4, shape=Shape.STANDARD
        )
        fake_state2 = _make_fake_state(sync_return=({}, [orphan]))
        out2 = io.StringIO()
        with mock.patch.object(colab_helper, "state", fake_state2), contextlib.redirect_stdout(out2):
            rc2 = colab_helper.cmd_adopt_existing("strata")
        self.assertEqual(rc2, 0)
        self.assertEqual(out2.getvalue().strip(), "ADOPTED_SESSION=strata:L4:STANDARD:m-s-adopted")
        self.assertIn("strata", fake_state2._stored)
        self.assertEqual(len(fake_state2._events), 1)

        fake_state3 = _make_fake_state(sync_return=({}, []))
        with mock.patch.object(colab_helper, "state", fake_state3):
            rc3 = colab_helper.cmd_adopt_existing("strata")
        self.assertEqual(rc3, 1)

    def test_assign_single_shape_post_assignment_success(self) -> None:
        fake_state = _make_fake_state()
        fake_state.client._get_assignment.return_value = types.SimpleNamespace(token="xsrf-tok")
        fake_state.client._post_assignment.return_value = _make_post_response(
            endpoint="m-s-post-ok",
            accelerator=Accelerator.A100,
            token="tok-post",
        )
        with mock.patch.object(colab_helper, "state", fake_state):
            rc = colab_helper._assign_single_shape("strata", Accelerator.A100, Shape.HIGH_RAM)
        self.assertEqual(rc, 0)
        self.assertIn("strata", fake_state._stored)
        saved = fake_state._stored["strata"]
        self.assertEqual(saved.endpoint, "m-s-post-ok")
        self.assertEqual(saved.token, "tok-post")
        self.assertEqual(saved.machine_shape, "HIGH_RAM")

    def test_assign_single_shape_412_fast_fail_no_sleep(self) -> None:
        fake_state = _make_fake_state()
        fake_state.client._get_assignment.side_effect = _make_request_error(412, "Precondition Failed")
        with (
            mock.patch.object(colab_helper, "state", fake_state),
            mock.patch.object(colab_helper.time, "sleep") as m_sleep,
            contextlib.redirect_stderr(io.StringIO()),
        ):
            rc = colab_helper._assign_single_shape("strata", Accelerator.G4, None)
        self.assertEqual(rc, 2)
        m_sleep.assert_not_called()
        self.assertEqual(fake_state.client._get_assignment.call_count, 1)

    def test_assign_single_shape_400_returns_3(self) -> None:
        fake_state = _make_fake_state()
        fake_state.client._get_assignment.side_effect = _make_request_error(400, "Bad Request")
        with (
            mock.patch.object(colab_helper, "state", fake_state),
            mock.patch.object(colab_helper.time, "sleep") as m_sleep,
            contextlib.redirect_stderr(io.StringIO()),
        ):
            rc = colab_helper._assign_single_shape("strata", Accelerator.H100, None)
        self.assertEqual(rc, 3)
        m_sleep.assert_not_called()

    def test_assign_single_shape_too_many_assignments_returns_4(self) -> None:
        fake_state = _make_fake_state()
        fake_state.client._get_assignment.side_effect = TooManyAssignmentsError("limit reached")
        with (
            mock.patch.object(colab_helper, "state", fake_state),
            mock.patch.object(colab_helper.time, "sleep") as m_sleep,
            contextlib.redirect_stderr(io.StringIO()),
        ):
            rc = colab_helper._assign_single_shape("strata", Accelerator.A100, Shape.HIGH_RAM)
        self.assertEqual(rc, 4)
        m_sleep.assert_not_called()

    def test_assign_single_shape_fast_503_under_20s_no_sleep(self) -> None:
        fake_state = _make_fake_state()
        fake_state.client._get_assignment.side_effect = _make_request_error(503, "No capacity")
        with (
            mock.patch.object(colab_helper, "state", fake_state),
            mock.patch.object(colab_helper.time, "monotonic", side_effect=[100.0, 104.2]),
            mock.patch.object(colab_helper.time, "sleep") as m_sleep,
            contextlib.redirect_stderr(io.StringIO()),
        ):
            rc = colab_helper._assign_single_shape("strata", Accelerator.G4, None)
        self.assertEqual(rc, 2)
        m_sleep.assert_not_called()
        self.assertEqual(fake_state.client._get_assignment.call_count, 1)

    def test_assign_single_shape_slow_503_over_20s_sleeps_8s_and_recovers(self) -> None:
        fake_state = _make_fake_state()
        recovered = _make_assignment(endpoint="m-s-coldboot")
        fake_state.client._get_assignment.side_effect = [
            types.SimpleNamespace(token="xsrf-tok"),
            recovered,
        ]
        fake_state.client._post_assignment.side_effect = _make_request_error(503, "Gateway timeout")

        with (
            mock.patch.object(colab_helper, "state", fake_state),
            mock.patch.object(colab_helper.time, "monotonic", side_effect=[100.0, 126.5]),
            mock.patch.object(colab_helper.time, "sleep") as m_sleep,
            contextlib.redirect_stderr(io.StringIO()),
        ):
            rc = colab_helper._assign_single_shape("strata", Accelerator.G4, None)

        self.assertEqual(rc, 0)
        m_sleep.assert_called_once_with(8)
        self.assertIn("strata", fake_state._stored)
        self.assertEqual(fake_state._stored["strata"].endpoint, "m-s-coldboot")
        self.assertEqual(fake_state._stored["strata"].machine_shape, "STANDARD")

    def test_assign_gpu_with_fallback_a100_high_ram_to_standard_none(self) -> None:
        self.assertEqual(resolve_assign_shape(Accelerator.A100, high_mem=True), Shape.HIGH_RAM)
        self.assertIsNone(resolve_assign_shape(Accelerator.A100, high_mem=False))

        fake_state = _make_fake_state(sync_return=({}, []))
        called_shapes: list[object] = []

        def fake_assign_single(name, acc, shape):
            called_shapes.append(shape)
            if shape == Shape.HIGH_RAM:
                return 2
            return 0

        err = io.StringIO()
        with (
            mock.patch.object(colab_helper, "state", fake_state),
            mock.patch.object(colab_helper, "_assign_single_shape", side_effect=fake_assign_single),
            contextlib.redirect_stderr(err),
        ):
            rc, chosen = colab_helper._assign_gpu_with_fallback("strata", "A100", "1")

        self.assertEqual(rc, 0)
        self.assertEqual(chosen, "STANDARD")
        self.assertEqual(called_shapes, [Shape.HIGH_RAM, None])
        self.assertIn("falling back to STANDARD", err.getvalue())

    def test_assign_gpu_with_fallback_single_shape_gpu_skips_high_ram(self) -> None:
        fake_state = _make_fake_state(sync_return=({}, []))
        called_shapes: list[object] = []

        def fake_assign_single(name, acc, shape):
            called_shapes.append(shape)
            return 0

        with (
            mock.patch.object(colab_helper, "state", fake_state),
            mock.patch.object(colab_helper, "_assign_single_shape", side_effect=fake_assign_single),
        ):
            rc, chosen = colab_helper._assign_gpu_with_fallback("strata", "G4", "1")

        self.assertEqual(rc, 0)
        self.assertEqual(chosen, "STANDARD")
        self.assertEqual(called_shapes, [None])

    def test_cmd_auto_assign_waterfall_g4_to_t4(self) -> None:
        fake_state = _make_fake_state(sync_return=({}, []))
        tried: list[str] = []

        def fake_fallback(name, gpu_str, high_mem_str):
            tried.append(gpu_str)
            if gpu_str == "T4":
                return 0, "STANDARD"
            if gpu_str == "H100":
                return 3, ""
            return 2, ""

        out, err = io.StringIO(), io.StringIO()
        with (
            mock.patch.object(colab_helper, "state", fake_state),
            mock.patch.object(colab_helper, "_assign_gpu_with_fallback", side_effect=fake_fallback),
            mock.patch.dict(os.environ, {"STRATA_UI_HOST": "1"}, clear=False),
            contextlib.redirect_stdout(out),
            contextlib.redirect_stderr(err),
        ):
            rc = colab_helper.cmd_auto_assign("strata", "G4,H100,A100,L4,T4", "1")

        self.assertEqual(rc, 0)
        self.assertEqual(tried, ["G4", "H100", "A100", "L4", "T4"])
        lines = out.getvalue().splitlines()
        self.assertIn("[STRATA_STATE:probing:G4]", lines)
        self.assertIn("[STRATA_STATE:probing:T4]", lines)
        self.assertEqual(lines[-1], "ASSIGNED_GPU=T4:STANDARD")

    def test_cmd_auto_assign_aborts_immediately_on_exit_4(self) -> None:
        fake_state = _make_fake_state(sync_return=({}, []))
        tried: list[str] = []

        def fake_fallback(name, gpu_str, high_mem_str):
            tried.append(gpu_str)
            return 4, ""

        with (
            mock.patch.object(colab_helper, "state", fake_state),
            mock.patch.object(colab_helper, "_assign_gpu_with_fallback", side_effect=fake_fallback),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            rc = colab_helper.cmd_auto_assign("strata", "G4,H100,A100,L4,T4", "1")

        self.assertEqual(rc, 4)
        self.assertEqual(tried, ["G4"])

    def test_main_argv_bounds_checks(self) -> None:
        bad_argvs = [
            ["colab-helper.py"],
            ["colab-helper.py", "unknown-cmd"],
            ["colab-helper.py", "info", "--session"],
            ["colab-helper.py", "info", "--bogus"],
            ["colab-helper.py", "adopt"],
            ["colab-helper.py", "assign", "strata", "G4"],
            ["colab-helper.py", "auto-assign", "strata", "G4,T4"],
        ]
        for argv in bad_argvs:
            with (
                self.subTest(argv=argv),
                mock.patch.object(sys, "argv", argv),
                contextlib.redirect_stderr(io.StringIO()) as err,
            ):
                rc = colab_helper.main()
                self.assertEqual(rc, 1)
                self.assertIn("Usage:", err.getvalue())

        with (
            mock.patch.object(sys, "argv", ["colab-helper.py", "info", "--json", "--session", "s1"]),
            mock.patch.object(colab_helper, "cmd_info", return_value=0) as m_info,
        ):
            self.assertEqual(colab_helper.main(), 0)
            m_info.assert_called_once_with(as_json=True, session_name="s1")


class TestColabWorkload(unittest.TestCase):
    """Tests for lib/colab-workload.py."""

    def test_scan_procs_active_setup_and_ignored(self) -> None:
        fake_cmds = {
            "101": b"python3\x00/tmp/colab-workload.py\x00",
            "102": b"python3\x00/tmp/strata-drive-cache.py\x00backup\x00/a\x00/b\x00",
            "103": b"python3\x00/content/Strata/strata.py\x00tune\x00--quick\x00",
            "104": b"bash\x00./setup.sh\x00--model\x00IQ3_S\x00",
        }

        def fake_open(path, mode="r", *args, **kwargs):
            for pid, data in fake_cmds.items():
                if path == f"/proc/{pid}/cmdline":
                    return io.BytesIO(data)
            raise OSError("missing")

        with (
            mock.patch.object(colab_workload.os, "listdir", return_value=["101", "102", "notpid"]),
            mock.patch("builtins.open", side_effect=fake_open),
        ):
            self.assertEqual(colab_workload._scan_procs(), (False, False))

        with (
            mock.patch.object(colab_workload.os, "listdir", return_value=["101", "103"]),
            mock.patch("builtins.open", side_effect=fake_open),
        ):
            self.assertEqual(colab_workload._scan_procs(), (True, False))

        with (
            mock.patch.object(colab_workload.os, "listdir", return_value=["102", "104"]),
            mock.patch("builtins.open", side_effect=fake_open),
        ):
            self.assertEqual(colab_workload._scan_procs(), (False, True))

        with (
            mock.patch.object(colab_workload.os, "listdir", return_value=["103", "104"]),
            mock.patch("builtins.open", side_effect=fake_open),
        ):
            self.assertEqual(colab_workload._scan_procs(), (True, True))

    def test_tune_progress_and_gpu_telemetry(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            status_path = os.path.join(td, "tune-1.status.json")
            with open(status_path, "w", encoding="utf-8") as f:
                json.dump(
                    {
                        "state": "running",
                        "runs_done": 4,
                        "runs_planned": 12,
                        "minutes_left": 7,
                        "arm": "kv_int8",
                    },
                    f,
                )
            with mock.patch.object(colab_workload.glob, "glob", return_value=[status_path]):
                self.assertEqual(colab_workload._tune_progress(), "tune(4/12, ~7m left, kv_int8)")

            with open(status_path, "w", encoding="utf-8") as f:
                json.dump({"state": "completed"}, f)
            with mock.patch.object(colab_workload.glob, "glob", return_value=[status_path]):
                self.assertIsNone(colab_workload._tune_progress())

        with mock.patch.object(
            colab_workload.subprocess, "check_output", return_value="64, 48120, 98304, 62\n"
        ):
            util, summary = colab_workload._gpu_telemetry()
            self.assertEqual(util, 64)
            self.assertEqual(summary, "GPU=64% VRAM=48120/98304 MiB 62C")

    def test_main_active_then_exits_after_idle_threshold_and_syncs_after_tune(self) -> None:
        scan_seq = [(True, False), (False, False), (False, False)]
        gpu_seq = [(45, "GPU=45% VRAM=1000/24000 MiB 55C"), (0, "GPU=0%"), (0, "GPU=0%")]
        mono_seq = [0.0, 5.0, 10.0, 15.0]
        out = io.StringIO()

        with (
            mock.patch.object(colab_workload, "IDLE_TICKS_TO_EXIT", 2),
            mock.patch.object(colab_workload, "MAX_WINDOW_SEC", 240),
            mock.patch.object(colab_workload, "POLL_SEC", 1),
            mock.patch.object(colab_workload, "_scan_procs", side_effect=scan_seq),
            mock.patch.object(colab_workload, "_tune_progress", return_value=None),
            mock.patch.object(colab_workload, "_drive_sync_progress", return_value=None),
            mock.patch.object(colab_workload, "_gpu_telemetry", side_effect=gpu_seq),
            mock.patch.object(colab_workload, "_sync_config_if_present") as m_sync,
            mock.patch.object(colab_workload.time, "monotonic", side_effect=mono_seq),
            mock.patch.object(colab_workload.time, "sleep") as m_sleep,
            contextlib.redirect_stdout(out),
        ):
            colab_workload.main()

        text = out.getvalue()
        self.assertIn("active=tune(running), gpu_compute", text)
        self.assertIn("Tuning completed; syncing presets to Google Drive", text)
        self.assertIn("VM idle", text)
        self.assertIn("Releasing Colab kernel", text)
        m_sync.assert_called_once()
        self.assertEqual(m_sleep.call_count, 2)

    def test_custom_drive_data_dir_and_remote_dir_env_overrides(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            drive_parent = os.path.join(td, "custom-mount")
            os.makedirs(drive_parent, exist_ok=True)
            custom_drive = os.path.join(drive_parent, "MyStrataDrive")
            custom_remote = os.path.join(td, "MyStrataRepo")

            with (
                mock.patch.dict(
                    os.environ,
                    {"DRIVE_DATA_DIR": custom_drive, "REMOTE_DIR": custom_remote},
                    clear=False,
                ),
                mock.patch.object(colab_workload.os.path, "isfile", return_value=True),
                mock.patch.object(colab_workload.subprocess, "run") as m_run,
            ):
                colab_workload._sync_config_if_present()

            m_run.assert_called_once_with(
                [
                    "python3",
                    "/tmp/strata-drive-cache.py",
                    "sync-config",
                    custom_drive,
                    custom_remote,
                ],
                check=False,
                timeout=30,
            )

            with mock.patch.dict(
                os.environ,
                {"DRIVE_DATA_DIR": custom_drive, "REMOTE_DIR": custom_remote},
                clear=False,
            ):
                fresh = _load_module_from_path("strata_colab_workload_env", COLAB_WORKLOAD_PATH)
                self.assertEqual(fresh.DRIVE_DATA_DIR, custom_drive)
                self.assertEqual(fresh.REMOTE_DIR, custom_remote)


class TestEmbeddedDriveCache(unittest.TestCase):
    """Tests for strata-drive-cache.py extracted in-memory from lib/remote-setup.sh."""

    def test_matches_model(self) -> None:
        self.assertTrue(drive_cache.matches_model("models/Qwen-IQ3_S.gguf", "IQ3_S"))
        self.assertTrue(drive_cache.matches_model("models/qwen-iq3_s.gguf.done", "IQ3_S"))
        self.assertTrue(drive_cache.matches_model("vision/mmproj-F16.gguf", "IQ3_S"))
        self.assertTrue(drive_cache.matches_model("dflash2/drafter.bin", "IQ3_S"))
        self.assertTrue(drive_cache.matches_model("packs/meta.json", "IQ3_S"))
        self.assertFalse(drive_cache.matches_model("models/Qwen-IQ3_S.gguf.part", "IQ3_S"))
        self.assertFalse(drive_cache.matches_model("models/Qwen-IQ3_S.gguf.tmp", "IQ3_S"))
        self.assertFalse(drive_cache.matches_model("models/Qwen-IQ3_S.gguf.incomplete", "IQ3_S"))
        self.assertFalse(drive_cache.matches_model("models/Qwen-IQ3_S.gguf.lock", "IQ3_S"))
        self.assertFalse(drive_cache.matches_model("conversation-spill/IQ3_S.json", "IQ3_S"))
        self.assertFalse(drive_cache.matches_model("strata-config/g4/presets/IQ3_S.json", "IQ3_S"))
        self.assertFalse(drive_cache.matches_model("models/Other-Q8_0.gguf", "IQ3_S"))

    def test_sanitize_run_config_and_desktop_state(self) -> None:
        raw_cfg = (
            b"\xef\xbb\xbf"
            + json.dumps(
                {"model_name": "qwen3.8", "port": 8090, "api_key": "sk-secret-123", "args": ["--port", "8090"]}
            ).encode("utf-8")
        )
        sanitized_cfg = drive_cache.sanitize_run_config(raw_cfg)
        self.assertIsNotNone(sanitized_cfg)
        parsed_cfg = json.loads(sanitized_cfg.decode("utf-8"))
        self.assertNotIn("api_key", parsed_cfg)
        self.assertEqual(parsed_cfg["model_name"], "qwen3.8")
        self.assertEqual(parsed_cfg["port"], 8090)
        self.assertIsNone(drive_cache.sanitize_run_config(b"{invalid"))
        self.assertIsNone(drive_cache.sanitize_run_config(b"[1, 2, 3]"))

        raw_state = json.dumps(
            {
                "theme": "dark",
                "serving": {"port": 8089, "apiKey": "sk-desktop-secret"},
            }
        ).encode("utf-8")
        sanitized_state = drive_cache.sanitize_desktop_state(raw_state)
        self.assertIsNotNone(sanitized_state)
        parsed_state = json.loads(sanitized_state.decode("utf-8"))
        self.assertIsNone(parsed_state["serving"]["apiKey"])
        self.assertEqual(parsed_state["serving"]["port"], 8089)
        self.assertEqual(parsed_state["theme"], "dark")
        self.assertIsNone(drive_cache.sanitize_desktop_state(b"not-json"))
        self.assertIsNone(drive_cache.sanitize_desktop_state(b'"scalar"'))

    @unittest.skipUnless(
        hasattr(os, "pread") and hasattr(os, "pwrite"),
        "Parallel pread/pwrite copy requires POSIX",
    )
    def test_copy_with_progress_parallel_integrity_and_fallbacks(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            src = os.path.join(td, "model.gguf")
            # 64 MiB + 131073 bytes -> 5 chunks across 4 ThreadPoolExecutor workers + uneven tail.
            hasher = hashlib.sha256()
            with open(src, "wb") as f:
                for blk in range(64):
                    tag = f"BLK{blk:04d}-".encode("ascii")
                    chunk = (tag * ((1024 * 1024) // len(tag) + 1))[: 1024 * 1024]
                    f.write(chunk)
                    hasher.update(chunk)
                tail = b"TAIL-END-" * (131073 // 9) + b"XYZ"
                tail = tail[:131073]
                f.write(tail)
                hasher.update(tail)
            expected_sha = hasher.hexdigest()

            def sha256_file(path: str) -> str:
                h = hashlib.sha256()
                with open(path, "rb") as fh:
                    while True:
                        b = fh.read(1024 * 1024)
                        if not b:
                            break
                        h.update(b)
                return h.hexdigest()

            # 1. Parallel 4-worker pread/pwrite path
            dst_par = os.path.join(td, "out-parallel", "model.gguf")
            real_pread = os.pread
            real_pwrite = os.pwrite
            counts = {"pread": 0, "pwrite": 0}

            def spy_pread(fd, n, off):
                counts["pread"] += 1
                return real_pread(fd, n, off)

            def spy_pwrite(fd, data, off):
                counts["pwrite"] += 1
                return real_pwrite(fd, data, off)

            with (
                mock.patch.object(drive_cache.os, "pread", side_effect=spy_pread),
                mock.patch.object(drive_cache.os, "pwrite", side_effect=spy_pwrite),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                drive_cache.copy_with_progress(src, dst_par, "test-par", parallel_read=True)

            self.assertGreaterEqual(counts["pread"], 16)
            self.assertGreaterEqual(counts["pwrite"], 16)
            self.assertEqual(sha256_file(dst_par), expected_sha)
            self.assertFalse(os.path.exists(dst_par + ".tmp"))

            # 2. EOFError in pread falls back cleanly to sequential copy
            dst_eof = os.path.join(td, "out-eof", "model.gguf")
            with (
                mock.patch.object(drive_cache.os, "pread", return_value=b""),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                drive_cache.copy_with_progress(src, dst_eof, "test-eof", parallel_read=True)
            self.assertEqual(sha256_file(dst_eof), expected_sha)
            self.assertFalse(os.path.exists(dst_eof + ".tmp"))

            # 3. OSError in pwrite falls back cleanly to sequential copy
            dst_oserr = os.path.join(td, "out-oserr", "model.gguf")
            with (
                mock.patch.object(
                    drive_cache.os, "pwrite", side_effect=OSError(errno.EIO, "simulated pwrite failure")
                ),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                drive_cache.copy_with_progress(src, dst_oserr, "test-oserr", parallel_read=True)
            self.assertEqual(sha256_file(dst_oserr), expected_sha)
            self.assertFalse(os.path.exists(dst_oserr + ".tmp"))

    def test_cmd_restore_config_pre_and_post(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            slug = "nvidia-rtx-pro-6000-blackwell"
            drive_dir = os.path.join(td, "drive", "Strata-data")
            remote_dir = os.path.join(td, "Strata")
            preset_dir = os.path.join(td, "home", ".config", "strata", "presets")
            profile_dir = os.path.join(td, "home", ".config", "strata", "profiles")
            desktop_state = os.path.join(td, "home", ".strata", "data", "state.json")

            cfg_root = os.path.join(drive_dir, "strata-config", slug)
            os.makedirs(os.path.join(cfg_root, "presets"), exist_ok=True)
            os.makedirs(os.path.join(cfg_root, "profiles"), exist_ok=True)
            os.makedirs(os.path.join(cfg_root, "desktop"), exist_ok=True)
            os.makedirs(os.path.join(cfg_root, "run-configs"), exist_ok=True)
            os.makedirs(os.path.join(remote_dir, "terminal"), exist_ok=True)

            # Populate Drive files for pre phase
            with open(os.path.join(cfg_root, "presets", "p1.json"), "w", encoding="utf-8") as f:
                json.dump(
                    {
                        "name": "tuned-room",
                        "created_epoch": 100.0,
                        "choices": {"model": "qwen3.8-flash", "context": 262144, "goal": "room"},
                    },
                    f,
                )
            with open(os.path.join(cfg_root, "presets", "active.json"), "w", encoding="utf-8") as f:
                json.dump({"entry1": {"active": "p1"}}, f)
            with open(os.path.join(cfg_root, "presets", "last-failed-engine.log"), "w", encoding="utf-8") as f:
                f.write("should be skipped")
            with open(os.path.join(cfg_root, "profiles", "prof.json"), "w", encoding="utf-8") as f:
                json.dump({"name": "default"}, f)
            with open(os.path.join(cfg_root, "profiles", "ignore.txt"), "w", encoding="utf-8") as f:
                f.write("not json")
            with open(os.path.join(cfg_root, "desktop", "state.json"), "w", encoding="utf-8") as f:
                json.dump({"serving": {"apiKey": None}}, f)

            # Populate local and saved run-config for post phase
            local_cfg_path = os.path.join(remote_dir, "strata-qwen38.json")
            with open(local_cfg_path, "w", encoding="utf-8") as f:
                json.dump(
                    {
                        "model_name": "qwen3.8-flash",
                        "port": 8080,
                        "args": ["--port", "8080", "--max-context", "131072"],
                        "args_written": ["--port=8080", "--max-context=131072"],
                    },
                    f,
                )
            saved_cfg_path = os.path.join(cfg_root, "run-configs", "strata-qwen38.json")
            with open(saved_cfg_path, "w", encoding="utf-8") as f:
                json.dump(
                    {
                        "model_name": "qwen3.8-flash",
                        "port": 9999,
                        "args": ["--port", "9999", "--max-context", "262144", "--threads", "16"],
                        "args_written": ["--port=9999", "--max-context=262144"],
                        "vram_reserve_mib": 1024,
                        "sampling": {"temp": 0.6},
                    },
                    f,
                )

            with (
                mock.patch.object(drive_cache, "detect_gpu_slug", return_value=slug),
                mock.patch.object(drive_cache, "PRESET_DIR", preset_dir),
                mock.patch.object(drive_cache, "PROFILE_DIR", profile_dir),
                mock.patch.object(drive_cache, "DESKTOP_STATE_FILE", desktop_state),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                rc_pre = drive_cache.cmd_restore_config(drive_dir, remote_dir, "pre")
                self.assertEqual(rc_pre, 0)
                self.assertTrue(os.path.isfile(os.path.join(preset_dir, "p1.json")))
                self.assertFalse(os.path.exists(os.path.join(preset_dir, "last-failed-engine.log")))
                self.assertTrue(os.path.isfile(os.path.join(profile_dir, "prof.json")))
                self.assertFalse(os.path.exists(os.path.join(profile_dir, "ignore.txt")))
                self.assertTrue(os.path.isfile(desktop_state))

                # Ensure desktop state is NOT overwritten when already present (only_if_missing=True)
                with open(desktop_state, "w", encoding="utf-8") as f:
                    json.dump({"local_only": True}, f)
                self.assertEqual(drive_cache.cmd_restore_config(drive_dir, remote_dir, "pre"), 0)
                with open(desktop_state, "r", encoding="utf-8") as f:
                    self.assertEqual(json.load(f), {"local_only": True})

                rc_post = drive_cache.cmd_restore_config(
                    drive_dir,
                    remote_dir,
                    "post",
                    context="262144",
                    port="8090",
                    ui_mode="desktop",
                )
                self.assertEqual(rc_post, 0)

            with open(local_cfg_path, "r", encoding="utf-8") as f:
                updated = json.load(f)

            self.assertEqual(updated["port"], 8090)
            self.assertEqual(updated["args"], ["--port", "8090", "--max-context", "262144", "--threads", "16"])
            self.assertEqual(updated["args_written"], ["--port=8090", "--max-context=262144"])
            self.assertEqual(updated["vram_reserve_mib"], 1024)
            self.assertEqual(updated["sampling"], {"temp": 0.6})
            self.assertTrue(updated["ui_context_chosen"])
            # Derived from restored active preset (goal="room" -> "work")
            self.assertEqual(updated["ui_resource_profile"], "work")

    def test_cmd_load_profile(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            remote_dir = os.path.join(td, "Strata")
            preset_dir = os.path.join(td, "presets")
            os.makedirs(remote_dir, exist_ok=True)
            os.makedirs(preset_dir, exist_ok=True)

            with open(os.path.join(remote_dir, "strata-iq3_s.json"), "w", encoding="utf-8") as f:
                json.dump({"model_name": "qwen3.8-flash-iq3_s", "ui_resource_profile": "performance"}, f)

            with open(os.path.join(preset_dir, "p_room.json"), "w", encoding="utf-8") as f:
                json.dump(
                    {
                        "created_epoch": 200.0,
                        "choices": {"model": "qwen3.8-flash-iq3_s", "context": 262144, "goal": "room"},
                    },
                    f,
                )
            with open(os.path.join(preset_dir, "p_speed.json"), "w", encoding="utf-8") as f:
                json.dump(
                    {
                        "created_epoch": 150.0,
                        "choices": {"model": "qwen3.8-flash-iq3_s", "context": 262144, "goal": "speed"},
                    },
                    f,
                )
            with open(os.path.join(preset_dir, "active.json"), "w", encoding="utf-8") as f:
                json.dump({"a": {"active": "p_room"}, "b": {"active": "p_speed"}}, f)

            out = io.StringIO()
            with mock.patch.object(drive_cache, "PRESET_DIR", preset_dir), contextlib.redirect_stdout(out):
                rc = drive_cache.cmd_load_profile(remote_dir, "IQ3_S", "262144")
            self.assertEqual(rc, 0)
            # preferred_profile="performance" selects speed preset even though room is newer
            self.assertEqual(out.getvalue().strip(), "performance")

            # Context with no matching preset falls back to ui_resource_profile
            out2 = io.StringIO()
            with mock.patch.object(drive_cache, "PRESET_DIR", preset_dir), contextlib.redirect_stdout(out2):
                rc2 = drive_cache.cmd_load_profile(remote_dir, "IQ3_S", "65536")
            self.assertEqual(rc2, 0)
            self.assertEqual(out2.getvalue().strip(), "performance")

            # Room-only preset returns "work"
            with open(os.path.join(preset_dir, "active.json"), "w", encoding="utf-8") as f:
                json.dump({"a": {"active": "p_room"}}, f)
            out3 = io.StringIO()
            with mock.patch.object(drive_cache, "PRESET_DIR", preset_dir), contextlib.redirect_stdout(out3):
                rc3 = drive_cache.cmd_load_profile(remote_dir, "IQ3_S", "262144")
            self.assertEqual(rc3, 0)
            self.assertEqual(out3.getvalue().strip(), "work")

    def test_is_healthy_accepts_health_and_api_health(self) -> None:
        class FakeResp:
            def __init__(self, status: int) -> None:
                self.status = status

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

        # Case 1: /health returns 200
        with mock.patch.object(drive_cache.urllib.request, "urlopen", return_value=FakeResp(200)) as m_open:
            self.assertTrue(drive_cache.is_healthy("8089"))
            self.assertEqual(m_open.call_count, 1)
            self.assertTrue(m_open.call_args[0][0].endswith("/health"))

        # Case 2: /health fails, /api/health returns 200
        def second_ok(url, timeout=3):
            if url.endswith("/api/health"):
                return FakeResp(200)
            raise OSError("connection refused")

        with mock.patch.object(drive_cache.urllib.request, "urlopen", side_effect=second_ok):
            self.assertTrue(drive_cache.is_healthy("8089"))

        # Case 3: both fail
        with mock.patch.object(drive_cache.urllib.request, "urlopen", side_effect=OSError("down")):
            self.assertFalse(drive_cache.is_healthy("8089"))

    def test_cmd_backup_loop_survives_drive_fuse_oserror(self) -> None:
        class _StopLoop(BaseException):
            pass

        with tempfile.TemporaryDirectory() as td:
            data_dir = os.path.join(td, "Strata-data")
            drive_parent = os.path.join(td, "MyDrive")
            drive_dir = os.path.join(drive_parent, "Strata-data")
            status_file = os.path.join(td, "sync.status")
            cfg_status_file = os.path.join(td, "config.status")
            os.makedirs(data_dir, exist_ok=True)
            os.makedirs(drive_parent, exist_ok=True)

            model_src = os.path.join(data_dir, "tiny-IQ3_S.gguf")
            with open(model_src, "wb") as f:
                f.write(b"GGUF-DATA-123456")
            with open(model_src + ".done", "w", encoding="utf-8") as f:
                f.write("ok\n")

            sleep_calls = {"n": 0}
            statuses_seen: list[str] = []
            real_write_status = drive_cache.write_status

            def track_status(text: str) -> None:
                statuses_seen.append(text)
                real_write_status(text)

            def bounded_sleep(_sec: float) -> None:
                sleep_calls["n"] += 1
                if sleep_calls["n"] > 3:
                    raise _StopLoop()

            usage_calls = {"n": 0}

            def flaky_disk_usage(_path: str):
                usage_calls["n"] += 1
                if usage_calls["n"] == 1:
                    raise OSError(errno.ENOTCONN, "Transport endpoint is not connected")
                return types.SimpleNamespace(total=100 * 1024**3, used=1 * 1024**3, free=99 * 1024**3)

            with (
                mock.patch.object(drive_cache, "STATUS_FILE", status_file),
                mock.patch.object(drive_cache, "CONFIG_STATUS_FILE", cfg_status_file),
                mock.patch.object(drive_cache, "write_status", side_effect=track_status),
                mock.patch.object(drive_cache, "is_calibrating", return_value=False),
                mock.patch.object(drive_cache, "is_healthy", return_value=True),
                mock.patch.object(drive_cache.time, "sleep", side_effect=bounded_sleep),
                mock.patch.object(drive_cache.shutil, "disk_usage", side_effect=flaky_disk_usage),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                with self.assertRaises(_StopLoop):
                    drive_cache.cmd_backup_loop(data_dir, drive_dir, "8089")

            # Loop survived the FUSE OSError, recorded ERROR, retried on tick 2, and reached DONE on tick 3.
            self.assertTrue(any(s.startswith("ERROR:") and "Transport endpoint" in s for s in statuses_seen))
            self.assertEqual(statuses_seen[-1], "DONE")
            backed_up = os.path.join(drive_dir, "tiny-IQ3_S.gguf")
            self.assertTrue(os.path.isfile(backed_up))
            self.assertTrue(os.path.isfile(backed_up + ".done"))
            with open(backed_up, "rb") as f:
                self.assertEqual(f.read(), b"GGUF-DATA-123456")

            # Also verify survival when copy_with_progress itself raises an OSError on first attempt
            os.remove(backed_up)
            os.remove(backed_up + ".done")
            sleep_calls["n"] = 0
            statuses_seen.clear()
            copy_calls = {"n": 0}
            real_copy = drive_cache.copy_with_progress

            def flaky_copy(*args, **kwargs):
                copy_calls["n"] += 1
                if copy_calls["n"] == 1:
                    raise OSError(errno.EIO, "Drive FUSE write error")
                return real_copy(*args, **kwargs)

            with (
                mock.patch.object(drive_cache, "STATUS_FILE", status_file),
                mock.patch.object(drive_cache, "CONFIG_STATUS_FILE", cfg_status_file),
                mock.patch.object(drive_cache, "write_status", side_effect=track_status),
                mock.patch.object(drive_cache, "is_calibrating", return_value=False),
                mock.patch.object(drive_cache, "is_healthy", return_value=True),
                mock.patch.object(drive_cache.time, "sleep", side_effect=bounded_sleep),
                mock.patch.object(
                    drive_cache.shutil,
                    "disk_usage",
                    return_value=types.SimpleNamespace(total=100 * 1024**3, used=0, free=100 * 1024**3),
                ),
                mock.patch.object(drive_cache, "copy_with_progress", side_effect=flaky_copy),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                with self.assertRaises(_StopLoop):
                    drive_cache.cmd_backup_loop(data_dir, drive_dir, "8089")

            self.assertTrue(any(s.startswith("ERROR:") and "Drive FUSE write error" in s for s in statuses_seen))
            self.assertEqual(statuses_seen[-1], "DONE")
            self.assertTrue(os.path.isfile(backed_up))


if __name__ == "__main__":
    unittest.main()
