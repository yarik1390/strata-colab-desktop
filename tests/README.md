# Strata Colab Desktop — Offline Test Suite

All tests in this directory run **100% offline** with **zero external packages** and **zero live Google Colab API calls** (no runtimes started or modified, no Compute Units consumed).

## Test Suites

| Suite | Platform | Coverage |
|---|---|---|
| [`test_repo_hygiene.py`](test_repo_hygiene.py) | WSL / Linux (and Windows) | LF/CRLF line endings, zero UTF-8 BOMs, pure ASCII `.ps1`/`.psm1`, tracked `.sh` mode `100755`, `bash -n`, `ssh -F ./ssh_config -G`, Colab notebook JSON/compile/clean-outputs + GPU threshold parity with `lib/common.sh`, and secret/PII scan. |
| [`test_python_helpers.py`](test_python_helpers.py) | WSL / Linux | Unit tests for `lib/colab-helper.py`, `lib/colab-workload.py`, and the embedded `strata-drive-cache.py` inside `lib/remote-setup.sh`. Automatically stubs `colab_cli` when `google-colab-cli` is not installed. |
| [`test_shell_scripts.sh`](test_shell_scripts.sh) | WSL / Linux | Standalone mocked harness (no `bats`) covering `lib/common.sh`, `status.sh --json`, `down.sh`, `ssh.sh`, `up.sh`, and `tune.sh`. |
| [`StrataHelpers.Tests.ps1`](StrataHelpers.Tests.ps1) | Windows (PowerShell 5.1) | PowerShell AST syntax checks, unit tests for all exported functions in `ui/StrataHelpers.psm1`, and `ui/StrataLauncher.ps1 -SmokeTest`. |

## Running Locally on WSL / Linux

Run from the repository root (`python3 -B` avoids creating `__pycache__` directories):

```bash
python3 -B -m unittest -v tests/test_repo_hygiene.py
python3 -B -m unittest -v tests/test_python_helpers.py
bash tests/test_shell_scripts.sh
```

If you have `google-colab-cli` installed via `uv`, you can also verify `test_python_helpers.py` against the real `colab_cli` package:

```bash
~/.local/share/uv/tools/google-colab-cli/bin/python -B -m unittest -v tests/test_python_helpers.py
```

## Running Locally on Windows

Run from PowerShell or Command Prompt in the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File tests\StrataHelpers.Tests.ps1
```

To run the WSL/Linux suites from Windows PowerShell in the repository root:

```powershell
wsl --exec bash -c 'python3 -B -m unittest -v tests/test_repo_hygiene.py && python3 -B -m unittest -v tests/test_python_helpers.py && bash tests/test_shell_scripts.sh'
```

## Continuous Integration

GitHub Actions (`.github/workflows/ci.yml`) automatically runs `linux-checks` on `ubuntu-latest` (Python 3.11 + Bash) and `windows-checks` on `windows-latest` (Windows PowerShell 5.1 `-STA`) on every push to `main`, pull request, and manual `workflow_dispatch`.
