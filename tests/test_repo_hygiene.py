#!/usr/bin/env python3
"""Offline repository hygiene and consistency checks for Strata Colab Desktop.

Runs cleanly on both Linux CI (ubuntu-latest) and Windows/WSL using only the
Python standard library (no external packages, no live Colab API calls).
"""

from __future__ import annotations

import ast
import json
import os
import re
import shutil
import subprocess
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

LF_EXTENSIONS = {".sh", ".py", ".env", ".md", ".ipynb", ".yml", ".yaml"}
LF_FILENAMES = {"ssh_config", ".gitattributes", ".gitignore"}
CRLF_EXTENSIONS = {".bat", ".ps1", ".psm1", ".vbs"}
ASCII_EXTENSIONS = {".ps1", ".psm1"}
BINARY_EXTENSIONS = {".ico", ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".pdf", ".zip"}

ALLOWED_EMAIL_DOMAINS = {
    "example.com",
    "example.org",
    "example.net",
    "example.invalid",
    "test.invalid",
    "localhost",
    "users.noreply.github.com",
}

SYNTHETIC_TOKEN_RE = re.compile(
    r"(?:test|fake|dummy|example|sample|mock|placeholder|redacted|123456|abcdef|000000|aaaaaa|xxxxxx)",
    re.IGNORECASE,
)

EMAIL_RE = re.compile(r"\b([A-Za-z0-9._%+-]+)@([A-Za-z0-9.-]+\.[A-Za-z]{2,})\b")
PRIVATE_KEY_RE = re.compile("-----BEGIN " + r"[A-Z0-9 ]*PRIVATE KEY-----")
HF_TOKEN_STRICT_RE = re.compile(r"\bhf_[A-Za-z0-9]{10,}\b")
HF_TOKEN_TEST_RE = re.compile(r"\bhf_[A-Za-z0-9]{24,}\b")
GOOGLE_OAUTH_STRICT_RE = re.compile(
    r"\bya29\.[A-Za-z0-9._-]{15,}\b|\b1//[A-Za-z0-9._-]{20,}\b|\bAIza[0-9A-Za-z_-]{35}\b"
)
GOOGLE_OAUTH_TEST_RE = re.compile(
    r"\bya29\.[A-Za-z0-9._-]{30,}\b|\b1//[A-Za-z0-9._-]{30,}\b|\bAIza[0-9A-Za-z_-]{35}\b"
)
LLM_KEY_STRICT_RE = re.compile(r"\bsk-(?:ant|proj)-[A-Za-z0-9_-]{20,}\b")


def _git_output(args: list[str]) -> str | None:
    if shutil.which("git") is None:
        return None
    proc = subprocess.run(
        ["git", *args],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        return None
    return proc.stdout


def tracked_files() -> list[Path]:
    """Return all git-tracked files that currently exist on disk."""
    out = _git_output(["ls-files", "-z"])
    if out is not None:
        rels = [p for p in out.split("\0") if p]
        return sorted(REPO_ROOT / r for r in rels if (REPO_ROOT / r).is_file())
    return _walk_fallback()


def repo_files() -> list[Path]:
    """Return tracked plus untracked non-ignored files (excludes .gitignore entries)."""
    out = _git_output(["ls-files", "--cached", "--others", "--exclude-standard", "-z"])
    if out is not None:
        rels = sorted({p for p in out.split("\0") if p})
        return [REPO_ROOT / r for r in rels if (REPO_ROOT / r).is_file()]
    return _walk_fallback()


def _walk_fallback() -> list[Path]:
    skip_dirs = {".git", ".state", "__pycache__", "docs"}
    found: list[Path] = []
    for root, dirs, files in os.walk(REPO_ROOT):
        dirs[:] = [d for d in dirs if d not in skip_dirs]
        for fn in files:
            if fn in {"config.local.env", ".env.local"} or fn.endswith((".pyc", ".pyo", ".log")):
                continue
            found.append(Path(root) / fn)
    return sorted(found)


def _rel(path: Path) -> str:
    return path.relative_to(REPO_ROOT).as_posix()


def _is_binary(path: Path, data: bytes) -> bool:
    if path.suffix.lower() in BINARY_EXTENSIONS:
        return True
    return b"\x00" in data[:8192]


def _strip_colab_magics(source: str) -> str:
    """Replace IPython/Colab % and ! magic lines with valid Python pass statements."""
    lines = source.splitlines(keepends=True)
    for line in lines:
        stripped = line.lstrip()
        if stripped:
            if stripped.startswith("%%"):
                return "pass\n"
            break
    out: list[str] = []
    for line in lines:
        stripped = line.lstrip()
        if stripped.startswith(("%", "!")):
            indent = line[: len(line) - len(stripped)]
            newline = "\n" if line.endswith("\n") else ""
            out.append(f"{indent}pass  # magic{newline}")
        else:
            out.append(line)
    return "".join(out)


def _extract_bash_function(script_text: str, func_name: str) -> str:
    pattern = re.compile(
        rf"^{re.escape(func_name)}\(\)\s*\{{.*?^\}}",
        re.MULTILINE | re.DOTALL,
    )
    match = pattern.search(script_text)
    if not match:
        raise AssertionError(f"Function {func_name}() not found in lib/common.sh")
    return match.group(0)


class TestRepoHygiene(unittest.TestCase):
    def test_line_endings(self) -> None:
        """LF-only on Unix/config/doc/CI files; CRLF-only on Windows scripts."""
        failures: list[str] = []
        checked_lf = 0
        checked_crlf = 0

        for path in repo_files():
            data = path.read_bytes()
            if _is_binary(path, data):
                continue
            suffix = path.suffix.lower()
            name = path.name

            if suffix in LF_EXTENSIONS or name in LF_FILENAMES:
                checked_lf += 1
                if b"\r\n" in data or b"\r" in data:
                    crlf_count = data.count(b"\r\n")
                    cr_count = data.count(b"\r") - crlf_count
                    failures.append(
                        f"{_rel(path)}: expected LF-only, found {crlf_count} CRLF and {cr_count} bare CR"
                    )
            elif suffix in CRLF_EXTENSIONS:
                checked_crlf += 1
                if not data:
                    continue
                stripped = data.replace(b"\r\n", b"")
                bare_lf = stripped.count(b"\n")
                bare_cr = stripped.count(b"\r")
                if bare_lf or bare_cr or (b"\r\n" not in data and len(data) > 0):
                    failures.append(
                        f"{_rel(path)}: expected CRLF-only, found {bare_lf} bare LF and {bare_cr} bare CR"
                    )

        self.assertGreater(checked_lf, 0, "No LF files discovered")
        self.assertGreater(checked_crlf, 0, "No CRLF files discovered")
        self.assertEqual(failures, [], "Line ending violations:\n" + "\n".join(failures))

    def test_no_utf8_bom_on_text_files(self) -> None:
        """Text files must not start with UTF-8 or UTF-16 BOM markers."""
        failures: list[str] = []
        for path in repo_files():
            data = path.read_bytes()
            if _is_binary(path, data):
                continue
            if data.startswith(b"\xef\xbb\xbf"):
                failures.append(f"{_rel(path)}: starts with UTF-8 BOM")
            elif data.startswith((b"\xff\xfe", b"\xfe\xff")):
                failures.append(f"{_rel(path)}: starts with UTF-16 BOM")
        self.assertEqual(failures, [], "BOM violations:\n" + "\n".join(failures))

    def test_powershell_files_pure_ascii(self) -> None:
        """PowerShell .ps1/.psm1 files must be pure ASCII to avoid PS 5.1 mojibake."""
        failures: list[str] = []
        checked = 0
        for path in repo_files():
            if path.suffix.lower() not in ASCII_EXTENSIONS:
                continue
            checked += 1
            data = path.read_bytes()
            try:
                data.decode("ascii")
            except UnicodeDecodeError as exc:
                text = data.decode("utf-8", errors="replace")
                line_no = data[: exc.start].count(b"\n") + 1
                bad_char = text[len(data[: exc.start].decode("utf-8", errors="replace"))]
                failures.append(
                    f"{_rel(path)}:{line_no}: non-ASCII byte 0x{data[exc.start]:02x} (U+{ord(bad_char):04X})"
                )
        self.assertGreater(checked, 0, "No PowerShell files discovered")
        self.assertEqual(failures, [], "Non-ASCII PowerShell violations:\n" + "\n".join(failures))

    def test_tracked_shell_scripts_executable_mode(self) -> None:
        """All tracked *.sh files must carry git executable mode 100755."""
        out = _git_output(["ls-files", "-s", "--", "*.sh", "lib/*.sh", "tests/*.sh"])
        if out is None:
            self.skipTest("git is not available in this environment")

        entries: dict[str, str] = {}
        for line in out.splitlines():
            if not line.strip():
                continue
            meta, rel_path = line.split("\t", 1)
            mode = meta.split()[0]
            entries[rel_path] = mode

        self.assertGreater(len(entries), 0, "Expected tracked *.sh files from git ls-files -s")
        bad = [f"{p} (mode {m}, expected 100755)" for p, m in sorted(entries.items()) if m != "100755"]
        self.assertEqual(bad, [], "Non-executable tracked shell scripts:\n" + "\n".join(bad))

    def test_bash_syntax_all_shell_scripts(self) -> None:
        """Run `bash -n` on every .sh file when running on Linux/WSL."""
        if os.name != "posix" or shutil.which("bash") is None:
            self.skipTest("Native POSIX bash not available on this platform")

        sh_files = [p for p in repo_files() if p.suffix.lower() == ".sh"]
        self.assertGreater(len(sh_files), 0, "No .sh files discovered")

        failures: list[str] = []
        for path in sh_files:
            proc = subprocess.run(
                ["bash", "-n", str(path)],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            if proc.returncode != 0:
                msg = (proc.stderr or proc.stdout).strip()
                failures.append(f"{_rel(path)}: {msg}")
        self.assertEqual(failures, [], "bash -n syntax failures:\n" + "\n".join(failures))

    def test_ssh_config_parses_cleanly(self) -> None:
        """Verify `ssh -F ./ssh_config -G colab-strata` resolves expected directives."""
        ssh_bin = shutil.which("ssh")
        if ssh_bin is None:
            self.skipTest("ssh client is not available")

        env = os.environ.copy()
        env["COLAB_SESSION"] = "strata"
        proc = subprocess.run(
            [ssh_bin, "-F", "./ssh_config", "-G", "colab-strata"],
            cwd=REPO_ROOT,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(
            proc.returncode,
            0,
            f"ssh -F ./ssh_config -G colab-strata failed:\n{proc.stderr}",
        )

        parsed: dict[str, str] = {}
        for line in proc.stdout.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) == 2:
                parsed.setdefault(parts[0].lower(), parts[1])

        self.assertEqual(parsed.get("hostname"), "colab-vm")
        self.assertEqual(parsed.get("user"), "root")
        self.assertEqual(parsed.get("identitiesonly"), "yes")
        self.assertEqual(parsed.get("controlmaster"), "auto")
        self.assertIn(parsed.get("stricthostkeychecking"), {"no", "false"})
        self.assertIn("colab ssh --proxy-mode", parsed.get("proxycommand", ""))
        self.assertTrue(
            parsed.get("controlpath", "").endswith("colab-cm-strata"),
            f"Unexpected controlpath: {parsed.get('controlpath')!r}",
        )

    def test_colab_notebook_structure_and_compile(self) -> None:
        """Validate Strata_Colab_Quickstart.ipynb JSON, clean outputs, and Python syntax."""
        nb_path = REPO_ROOT / "notebooks" / "Strata_Colab_Quickstart.ipynb"
        self.assertTrue(nb_path.is_file(), f"Missing notebook: {nb_path}")

        nb = json.loads(nb_path.read_text(encoding="utf-8"))
        self.assertIsInstance(nb, dict)
        self.assertGreaterEqual(nb.get("nbformat", 0), 4)
        cells = nb.get("cells")
        self.assertIsInstance(cells, list)
        self.assertGreater(len(cells), 0)

        code_cells = 0
        for idx, cell in enumerate(cells):
            if cell.get("cell_type") != "code":
                continue
            code_cells += 1
            self.assertEqual(
                cell.get("outputs"),
                [],
                f"Notebook cell #{idx} has non-empty outputs",
            )
            self.assertIsNone(
                cell.get("execution_count"),
                f"Notebook cell #{idx} has non-null execution_count: {cell.get('execution_count')!r}",
            )
            raw_src = "".join(cell.get("source", []))
            filename = f"{_rel(nb_path)}#cell-{idx}"
            try:
                tree = ast.parse(raw_src, filename=filename)
                compile(tree, filename, "exec")
            except SyntaxError:
                cleaned = _strip_colab_magics(raw_src)
                tree = ast.parse(cleaned, filename=filename)
                compile(tree, filename, "exec")

        self.assertGreater(code_cells, 0, "Notebook has no code cells")

    def test_notebook_and_common_sh_gpu_thresholds_match(self) -> None:
        """Verify notebook Auto GPU thresholds match lib/common.sh across all tiers."""
        nb_path = REPO_ROOT / "notebooks" / "Strata_Colab_Quickstart.ipynb"
        common_path = REPO_ROOT / "lib" / "common.sh"

        nb = json.loads(nb_path.read_text(encoding="utf-8"))
        common_text = common_path.read_text(encoding="utf-8")

        # Locate the Auto GPU selection AST nodes in the notebook
        target_nodes: list[ast.stmt] = []
        for cell in nb.get("cells", []):
            if cell.get("cell_type") != "code":
                continue
            src = "".join(cell.get("source", []))
            if "is_blackwell" in src and 'MODEL_PRESET == "Auto (match GPU)"' in src:
                tree = ast.parse(_strip_colab_magics(src))
                for stmt in tree.body:
                    if isinstance(stmt, ast.Assign) and any(
                        isinstance(t, ast.Name) and t.id == "is_blackwell" for t in stmt.targets
                    ):
                        target_nodes.append(stmt)
                    elif isinstance(stmt, ast.If) and "Auto (match GPU)" in ast.dump(stmt.test):
                        target_nodes.append(stmt)
                break

        self.assertEqual(
            len(target_nodes),
            2,
            "Could not locate is_blackwell assignment and Auto (match GPU) selector in notebook",
        )
        selector_mod = ast.fix_missing_locations(ast.Module(body=target_nodes, type_ignores=[]))
        selector_code = compile(selector_mod, "<notebook-auto-gpu>", "exec")

        # Verify static threshold markers in lib/common.sh
        self.assertIn("RTX PRO 6000|BLACKWELL|B200|B100", common_text)
        self.assertIn("VM_VRAM_GB >= 90", common_text)
        self.assertIn("VM_VRAM_GB >= 40 && VM_RAM_GB >= 80", common_text)
        self.assertIn("VM_VRAM_GB >= 22 && VM_RAM_GB >= 48", common_text)
        self.assertIn('MODEL_FAMILY="nvfp4"', common_text)
        self.assertIn('MODEL="NVFP4"', common_text)
        self.assertIn('MODEL="IQ3_S"', common_text)
        self.assertIn('MODEL="IQ2_XS"', common_text)
        self.assertIn('MODEL_FAMILY="qwen36"', common_text)
        self.assertIn('MODEL="UD-Q4_K_XL"', common_text)

        cases = [
            # (gpu_name, vram_gb, ram_gb, expected_family, expected_model)
            ("NVIDIA RTX PRO 6000 Blackwell", 98, 176, "nvfp4", "NVFP4"),
            ("NVIDIA B200", 90, 128, "nvfp4", "NVFP4"),
            ("NVIDIA RTX PRO 6000 Blackwell", 80, 128, "", "IQ3_S"),
            ("NVIDIA H100 80GB HBM3", 80, 167, "", "IQ3_S"),
            ("NVIDIA A100-SXM4-40GB", 40, 80, "", "IQ3_S"),
            ("NVIDIA A100-SXM4-40GB", 40, 52, "", "IQ2_XS"),
            ("NVIDIA L4", 23, 52, "", "IQ2_XS"),
            ("NVIDIA L4", 22, 48, "", "IQ2_XS"),
            ("NVIDIA L4", 22, 32, "qwen36", "UD-Q4_K_XL"),
            ("Tesla T4", 15, 51, "qwen36", "UD-Q4_K_XL"),
            ("Tesla T4", 15, 13, "qwen36", "UD-Q4_K_XL"),
        ]

        # 1. Evaluate the notebook's actual auto-selection logic
        for gpu_name, vram_gb, ram_gb, exp_family, exp_model in cases:
            ns = {
                "re": re,
                "MODEL_PRESET": "Auto (match GPU)",
                "PRESET_MAP": {},
                "gpu_name": gpu_name,
                "vram_gb": vram_gb,
                "ram_gb": ram_gb,
            }
            exec(selector_code, ns)  # noqa: S102
            self.assertEqual(
                (ns["MODEL_FAMILY"], ns["MODEL"]),
                (exp_family, exp_model),
                f"Notebook mismatch for {gpu_name} ({vram_gb}GB VRAM, {ram_gb}GB RAM)",
            )

        # 2. Cross-check lib/common.sh live in bash when POSIX bash is available
        if os.name == "posix" and shutil.which("bash") is not None:
            fn_slot = _extract_bash_function(common_text, "recommended_model_slot")
            fn_resolve = _extract_bash_function(common_text, "resolve_auto_model")
            runner = (
                "set -euo pipefail\n"
                "probe_vm_memory_gb() { :; }\n"
                "log() { :; }\n"
                "msg() { :; }\n"
                f"{fn_slot}\n"
                f"{fn_resolve}\n"
                'MODEL_REPO=""\n'
                'MODEL="AUTO"\n'
                'MODEL_FAMILY=""\n'
                'GPU=""\n'
                'VM_GPU_NAME="$1"\n'
                'VM_VRAM_GB="$2"\n'
                'VM_RAM_GB="$3"\n'
                'resolve_auto_model ""\n'
                "printf '%s\\t%s\\n' \"$MODEL_FAMILY\" \"$MODEL\"\n"
            )
            for gpu_name, vram_gb, ram_gb, exp_family, exp_model in cases:
                proc = subprocess.run(
                    ["bash", "-c", runner, "_", gpu_name, str(vram_gb), str(ram_gb)],
                    capture_output=True,
                    text=True,
                    check=True,
                )
                got_family, got_model = proc.stdout.rstrip("\n").split("\t", 1)
                self.assertEqual(
                    (got_family, got_model),
                    (exp_family, exp_model),
                    f"lib/common.sh mismatch for {gpu_name} ({vram_gb}GB VRAM, {ram_gb}GB RAM)",
                )

    def test_no_hardcoded_secrets_or_personal_emails(self) -> None:
        """Repo files must contain zero personal emails, OAuth/HF tokens, or private keys."""
        findings: list[str] = []
        files = repo_files()
        self.assertGreater(len(files), 0, "No repository files discovered")

        for path in files:
            data = path.read_bytes()
            if _is_binary(path, data):
                continue
            rel = _rel(path)
            is_test_file = rel.startswith("tests/")
            text = data.decode("utf-8", errors="replace")

            for line_no, line in enumerate(text.splitlines(), start=1):
                if PRIVATE_KEY_RE.search(line):
                    findings.append(f"{rel}:{line_no}: private key material detected")

                for m in EMAIL_RE.finditer(line):
                    domain = m.group(2).lower()
                    if domain not in ALLOWED_EMAIL_DOMAINS:
                        findings.append(f"{rel}:{line_no}: email address detected ({m.group(0)})")

                hf_re = HF_TOKEN_TEST_RE if is_test_file else HF_TOKEN_STRICT_RE
                for m in hf_re.finditer(line):
                    if is_test_file and SYNTHETIC_TOKEN_RE.search(m.group(0)):
                        continue
                    findings.append(f"{rel}:{line_no}: Hugging Face token pattern detected")

                oauth_re = GOOGLE_OAUTH_TEST_RE if is_test_file else GOOGLE_OAUTH_STRICT_RE
                for m in oauth_re.finditer(line):
                    if is_test_file and SYNTHETIC_TOKEN_RE.search(m.group(0)):
                        continue
                    findings.append(f"{rel}:{line_no}: Google OAuth/API token pattern detected")

                for m in LLM_KEY_STRICT_RE.finditer(line):
                    if is_test_file and SYNTHETIC_TOKEN_RE.search(m.group(0)):
                        continue
                    findings.append(f"{rel}:{line_no}: LLM provider API key pattern detected")

        self.assertEqual(findings, [], "Secret/PII scan findings:\n" + "\n".join(findings))


if __name__ == "__main__":
    unittest.main()
