# Strata Colab Desktop

[![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/yarik1390/strata-colab-desktop/blob/main/notebooks/Strata_Colab_Quickstart.ipynb)

Run the full **[Strata Desktop Application](https://github.com/Niko1221/Strata)** (with **Native G4 Blackwell `NVFP4`**, **256K context**, **Fast Cold Starts via `HF_XET_HIGH_PERFORMANCE` + `STRATA_UV`**, **1-Click Hardware Auto-Tuning**, **Instant Google Drive Preset Persistence**, and local **OpenAI / Anthropic API endpoints**) on a paid **Google Colab GPU** runtime (`G4 RTX PRO 6000 Blackwell`, `H100`, `A100`, `L4`, or `T4`) for personal interactive research, forwarded strictly to **`http://localhost:8080`** (`127.0.0.1`) on your local machine over the official Google Colab CLI SSH tunnel.

---

## Key Features

- **Windows Desktop Control Panel (`launcher.bat` & `create-shortcut.bat`)**: Native dark WPF launcher with **Minimize-to-Tray** and Windows notifications, **Live Telemetry** (auto-refreshing GPU VRAM, utilization, temperature, active model, and estimated session Compute Unit burn), a one-click **Connect Client** dialog for coding agents, **Log Filter/Search**, **Export Redacted Diagnostics**, and safe shutdown prompts.
- **Full Strata Desktop UI (`UI_MODE=desktop`)**: Builds and runs Strata's complete desktop interface (`app/host`) directly on the Colab GPU VM — giving you Chat, Files & Workspace, Live Code Preview, the Models Manager, 1-Click Engine Auto-Tuning, Live Telemetry, and OpenAI (`/v1`) & Anthropic (`/v1/messages`) API gateways at `http://localhost:8080`.
- **Native G4 Blackwell `NVFP4`, Engine Controls & 256K Context (`CONTEXT=262144`)**: `MODEL=AUTO` detects G4 RTX PRO 6000 Blackwell (>= 90 GB VRAM) and runs native Blackwell FP4 (`--family nvfp4 --model NVFP4` + `STRATA_PREFILL_NVFP4=w4a4`), keeping all experts VRAM-resident, while matching A100/H100 (`IQ3_S`), L4 (`IQ2_XS`), and T4 (`qwen36` `UD-Q4_K_XL`). Configure KV cache quantization (`STRATA_KV_CACHE`), vision (`STRATA_VISION`), and speculative drafting (`STRATA_DRAFTER`) from the Launcher UI or `config.env`.
- **Smart GPU Discovery & Automatic Fallback (`GPU=AUTO`)**: Queries Google Colab for your Compute Unit balance and eligible GPUs (`G4 -> H100 -> A100 -> L4 -> T4`). Automatically handles single-shape high-memory GPUs (`G4` 98 GB VRAM / 176 GB RAM, `H100` 80 GB VRAM / 167 GB RAM, `L4` 23 GB VRAM / 52 GB RAM), `HIGH_RAM -> STANDARD` fallback, pool exhaustion (`412`/`503`), and fast-fail on concurrent session limits.
- **Fast Cold-Start Pipeline & Google Drive Persistence (`USE_DRIVE=1`, `DRIVE_MODEL_CACHE=0`)**:
  - **Instant Tuned Preset & Config Persistence (Default)**: With `USE_DRIVE=1` and `DRIVE_MODEL_CACHE=0`, Google Drive mounts `/content/drive/MyDrive/Strata-data` to restore and persist auto-tune presets (`/root/.config/strata/presets`), serving profiles, and sanitized per-GPU configs (with API keys stripped) under `$DRIVE_DATA_DIR/strata-config/<gpu-model>/` in **`<1s`**.
  - **Direct High-Speed Hugging Face Downloads**: By default (`DRIVE_MODEL_CACHE=0`), models download directly onto Colab's local NVMe SSD (`/content/Strata-data`) using **`HF_XET_HIGH_PERFORMANCE=1`** and **`STRATA_UV=1`** to saturate datacenter links and minimize cold-start time.
  - **Optional Google Drive Model Cache (`DRIVE_MODEL_CACHE=1`)**: Enable `DRIVE_MODEL_CACHE=1` to perform parallel SSD restore of cached `.gguf`, `.done`, `packs/`, and `dflash2/` files matching your selected model, plus automatic background backup to Google Drive (automatically pausing during GPU calibration benchmarks).
- **Opt-In Idle Auto-Stop (`AUTO_STOP_IDLE_MIN`)**: Optionally shut down the Colab VM cleanly after a configurable number of idle minutes (`0` = disabled) so forgotten GPU sessions stop consuming Compute Units.

---

## Requirements

- **Windows 10 / 11** with **Ubuntu on WSL2** (or native Linux / macOS with `bash`)
- A **Google Account** with a **paid Google Colab plan and a positive compute unit balance** (Colab Pro, Colab Pro+, or Pay-As-You-Go) — required by Google Colab's policies for SSH and WebUI workflows and for `G4`, `H100`, `A100`, and `L4` GPUs

---

## Quick Start

### 1. One-Time WSL Setup

Open a WSL Ubuntu terminal in this project directory and run:

```bash
bash ./setup-wsl.sh
export PATH="$HOME/.local/bin:$PATH"
colab usage
```

The first `colab usage` command prints a Google OAuth link — open it in your browser, sign in to your Google Colab account, and paste the authorization code into the terminal.

### 2. Launch Strata Desktop

#### Option A: Windows Desktop Launcher UI (Recommended on Windows)

Double-click **`launcher.bat`** — or run **`create-shortcut.bat`** once to add a **`Strata Colab Desktop`** icon to your Windows Desktop:

- **One-Click Launch & Hardware Controls**: Pick **`GPU=AUTO`** (`G4 -> H100 -> A100 -> L4 -> T4`), **`MODEL=AUTO`** (or explicit presets including **`Qwen3.8-Flash [NVFP4] (G4 Blackwell)`**), Context length, and expand **Advanced Engine & Custom HF** for `STRATA_KV_CACHE`, `STRATA_VISION`, `STRATA_DRAFTER`, `AUTO_STOP_IDLE_MIN`, and custom Hugging Face GGUF repos.
- **Live Telemetry & System Tray**: Auto-refreshes GPU VRAM used/total, GPU utilization, temperature, active model, and estimated session Compute Unit burn every 20 seconds (`./status.sh --json`). Minimize to the **System Tray** with live status notifications for `Tunnel Ready`, `Drive OAuth Required`, `Auto-Tune Done`, and errors.
- **Connect Client & Diagnostics**: Open **Connect Client** to copy or apply coding-agent configs (including Claude Code with KV-cache protection), filter/search live logs, open an interactive SSH shell or remote log viewer, and export a redacted diagnostics bundle with one click.

#### Option B: Interactive CLI (`start.bat` / `./up.sh`)

On Windows, double-click **`start.bat`** (or run `./up.sh` inside WSL):

1. **Choose a GPU**: The script displays your Compute Unit balance and an interactive menu of eligible GPUs for your account (defaulting to **`0) AUTO`**):
   ```text
   Eligible GPUs for your Google Colab account:
       0) AUTO  (try best available: G4 -> H100 -> A100 -> L4 -> T4) [default]
       1) G4    (RTX PRO 6000 Blackwell: 98 GB VRAM / 176 GB RAM)
       2) H100  (80 GB VRAM / ~167 GB RAM)
       3) A100  (40-80 GB VRAM / ~83-167 GB RAM)
       4) L4    (23 GB VRAM / 52 GB RAM)
       5) T4    (15 GB VRAM / 12.7-51 GB RAM)
   ```
2. **Authorize Google Drive (First Run Only)**: `colab drivemount` mounts `/content/drive` on the Colab VM so tuned per-GPU presets and configs persist across sessions in `<1s` (and model files too if you enable `DRIVE_MODEL_CACHE=1`).
3. **Choose a Model**: Models are recommended based on the allocated VM's actual VRAM/RAM (with `[Cached in Google Drive - fast start!]` badges shown when `DRIVE_MODEL_CACHE=1` is enabled):
   ```text
   Choose a Strata model to run (GPU: G4 / Context: 262144 tokens):
       1) Qwen3.6-35B-A3B  [UD-Q4_K_XL]  (22.9 GB download, ~4-5 min start, fits L4/T4)
       2) Qwen3.8-Flash    [IQ2_XS]      (~68 GB download, 35.5 GB RAM, recommended for L4 52GB)
       3) Qwen3.8-Flash    [Q2_0]        (~66 GB download, 34.0 GB RAM, fastest full Qwen3.8)
       4) Qwen3.8-Coder    [IQ1_M]       (~36 GB download, 23.0 GB RAM, coding specialist)
       5) Qwen3.8-Flash    [IQ3_S]       (~84 GB download, 50.0 GB RAM, best for A100/H100)
       6) Qwen3.8-Flash    [NVFP4]       (~63 GB download, native FP4, best for G4 Blackwell) [default]
   ```
4. **Chat, Code & Tune**: Once ready, your browser opens **`http://localhost:8080`** to the full **Strata Desktop App**.

#### Option C: Run Directly in Google Colab (No WSL Required)

Prefer running directly inside a Colab notebook (for example from any browser or mobile device)? Open **[`notebooks/Strata_Colab_Quickstart.ipynb`](notebooks/Strata_Colab_Quickstart.ipynb)** via **[Open in Colab](https://colab.research.google.com/github/yarik1390/strata-colab-desktop/blob/main/notebooks/Strata_Colab_Quickstart.ipynb)**:

- Verifies GPU runtime availability, aligns `Auto (match GPU)` selection with `lib/common.sh` (including G4 Blackwell **`NVFP4`**), enables `HF_XET_HIGH_PERFORMANCE=1` & `STRATA_UV=1` with optional `KV_CACHE`/`VISION`/`DRAFTER` controls, and runs streaming + long-context benchmarks.
- Syncs per-GPU tuned presets with `/content/drive/MyDrive/Strata-data/strata-config/<gpu>/presets` (with opt-in model-filtered `DRIVE_MODEL_CACHE`), cleanly restarts Strata if you switch models mid-session, and includes a **Stop Server & Sync Presets** cell.

---

## Connect Coding Agents (Claude Code, Cursor, Cline)

While the local SSH tunnel is active, Strata exposes strictly local (`127.0.0.1`) endpoints:

- **Strata Desktop UI**: `http://localhost:8080`
- **OpenAI-Compatible API**: `http://localhost:8080/v1`
- **Anthropic Messages API**: `http://localhost:8080/v1/messages`

In the Windows Desktop Launcher (`launcher.bat`), click **`Connect Client`** for ready-to-copy configurations and a one-click helper to update `~/.claude/settings.json` (with confirmation).

### Claude Code (`~/.claude/settings.json`)

> **Important (Prefix / KV Cache Preservation):** By default, Claude Code injects a per-request changing `x-anthropic-billing-header` into system prompts, which invalidates Strata's prefix/KV cache on every turn (~90% prefill slowdown). Always set `"CLAUDE_CODE_ATTRIBUTION_HEADER": "0"` when connecting Claude Code to Strata:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://localhost:8080",
    "ANTHROPIC_AUTH_TOKEN": "strata-local",
    "CLAUDE_CODE_ATTRIBUTION_HEADER": "0"
  }
}
```

If you configured a custom `API_KEY` in `config.local.env`, replace `"strata-local"` with your `API_KEY`.

### Cursor, Cline, Continue & OpenAI SDK

- **Provider / API Type**: OpenAI-Compatible
- **Base URL**: `http://localhost:8080/v1`
- **API Key**: `strata-local` (or your `API_KEY` from `config.local.env`)
- **Model**: Select the active model returned by `GET http://localhost:8080/v1/models` (also shown in the Desktop Launcher telemetry header).

---

## Commands & Scripts

| Action | Windows | WSL / Linux |
|---|---|---|
| **Open the Strata Colab Desktop Launcher UI** | `launcher.bat` | — |
| **Create the Windows Desktop shortcut with custom icon** | `create-shortcut.bat` | — |
| **Start runtime, mount Drive & open Strata Desktop (CLI)** | `start.bat` | `./up.sh` |
| **Run or monitor Auto-Tune via active `colab exec`** | `tune.bat` | `./tune.sh` |
| **Restart Strata after editing `config.env` (keeps VM & models)** | `restart.bat` | `./restart.sh` |
| **Sync presets, stop runtime & stop Compute Unit billing** | `stop.bat` | `./down.sh` |
| **Check runtime, GPU telemetry, Drive sync & tunnel status** | `status.bat` | `./status.sh` (`--json` for JSON) |
| **Stream live remote logs** | — | `./logs.sh` |
| **Open an interactive SSH shell on the Colab VM** | — | `./ssh.sh` |
| **Reconnect the local SSH tunnel to a running VM** | — | `./tunnel.sh` |

---

## Configuration (`config.env`)

All defaults live in [`config.env`](config.env). For private tokens (`HF_TOKEN`, `API_KEY`) or local overrides (also written by the Desktop Launcher UI), create or edit `config.local.env` (automatically ignored by Git).

| Variable | Default | Description |
|---|---|---|
| `GPU` | `AUTO` | `AUTO` (try best available `G4 -> H100 -> A100 -> L4 -> T4`), or explicit GPU (`G4`, `H100`, `A100`, `L4`, `T4`) |
| `ASK_GPU` | `1` | Prompt to select an eligible GPU at startup (supports `0) AUTO`) with `HIGH_RAM -> STANDARD` and pool-capacity fallback (`412`/`503`) |
| `HIGH_MEM` | `1` | Request High-RAM shape when supported (`A100`, `T4`), with automatic fallback to `STANDARD` shape if the High-RAM pool is full |
| `UI_MODE` | `desktop` | `desktop` = full Strata Desktop UI (`app/host`); `cli` = headless Strata CLI server |
| `MODEL` | `AUTO` | `AUTO` (G4 Blackwell >= 90 GB -> `NVFP4`, A100/H100 -> `IQ3_S`, L4 -> `IQ2_XS`, T4 -> `qwen36` `UD-Q4_K_XL`), or explicit quant (`NVFP4`, `IQ3_S`, `IQ2_XS`, `Q2_0`, `IQ1_M`, `UD-Q4_K_XL`, etc.) |
| `MODEL_FAMILY` | `''` | Optional model family (`nvfp4`, `qwen`, `qwen36`, `coder`, `unsloth`, `swift`, `gyro`; empty = Strata default; `nvfp4` exports `STRATA_PREFILL_NVFP4=w4a4`) |
| `ASK_MODEL` | `1` | Prompt to select a model matched to your GPU memory (badges Drive-cached models when `DRIVE_MODEL_CACHE=1`) |
| `CONTEXT` | `262144` | Context window size in tokens (`262144` = 256K tokens) |
| `TUNE_ON_START` | `0` | Set to `1` to automatically run Strata hardware calibration/tuning before loading |
| `HF_XET_HIGH_PERFORMANCE` | `1` | Enable high-throughput Hugging Face Xet downloads to saturate Colab datacenter bandwidth |
| `STRATA_UV` | `1` | Use `uv` inside Strata's `setup.sh` for fast Python environment installation |
| `STRATA_KV_CACHE` | `''` | Optional KV cache quantization passed as `--kv` (`int8`, `q4_0`, `k8v4`, `fp16`; empty = Strata default) |
| `STRATA_VISION` | `''` | Optional vision encoder mode passed as `--vision` (`yes`, `no`, `none`, `gpu`, `cpu`; empty = Strata default) |
| `STRATA_DRAFTER` | `''` | Optional speculative drafter passed as `--drafter` (`mtp`, `dflash2`; empty = Strata default) |
| `USE_DRIVE` | `1` | Mount Google Drive to persist tuned presets & sanitized per-GPU configs in `<1s` |
| `DRIVE_MODEL_CACHE` | `0` | `0` = config/preset persistence only, downloading GGUF directly from Hugging Face (default, fast); `1` = also perform parallel model-filtered restore & background backup of GGUF files via Google Drive |
| `DRIVE_DATA_DIR` | `/content/drive/MyDrive/Strata-data` | Google Drive folder used for `strata-config/<gpu>/` presets and optional model cache |
| `LOCAL_PORT` | `8080` | Local port on Windows / WSL forwarded to the Colab VM |
| `AUTO_STOP_IDLE_MIN` | `0` | Opt-in idle auto-stop in minutes (`0` = disabled; when `> 0`, stops the Colab VM cleanly after N idle minutes) |
| `ACTIVE_WORKLOAD_MONITOR` | `1` | Report active tuning/GPU/setup progress via `colab exec` (exits automatically when idle) |

Custom Hugging Face GGUF repositories (`MODEL_REPO`, `MODEL_FILES`, `MODEL_REVISION`) and extra CLI arguments (`STRATA_EXTRA_ARGS`) can also be configured in `config.local.env` or in the Desktop Launcher's **Advanced Engine & Custom HF** drawer.

---

## Google Colab Terms of Service Compliance

This project is designed for personal interactive research in accordance with the [Google Colab Terms of Service](https://research.google.com/colaboratory/tos_v6.html) and [Google Colab FAQ](https://research.google.com/colaboratory/faq.html):

- **Paid Compute Units Required**: Per the Google Colab FAQ, remote SSH shells and interacting primarily through a WebUI instead of the notebook UI are disallowed on free runtimes without a positive compute unit balance. Maintain a positive paid compute unit balance (Colab Pro, Colab Pro+, or Pay-As-You-Go) when using this project.
- **Local-Only Personal Research (`127.0.0.1`)**: Port forwarding is bound strictly to `127.0.0.1` via Google's official `google-colab-cli` SSH tunnel for interactive personal research. Do **not** expose endpoints publicly (`0.0.0.0`, ngrok, Cloudflare tunnels, reverse proxies), run a web service offering, or share/resell access to third parties.
- **Active-Workload Kernel Reporting (`colab exec`)**: This project never runs dummy idle keepalive loops. Instead, while real GPU/tuning/setup work is active, it streams genuine progress and telemetry through Google Colab's official `colab exec` channel (or `./tune.sh` / `tune.bat`) and releases the kernel immediately when the VM becomes idle. Always stop your VM (`stop.bat`, `./down.sh`, or the Launcher's **Stop VM** button) when finished.

---

## Important Notes

- **Always Stop When Finished**: Closing the `start.bat` terminal window (or detaching the tunnel) closes only the local SSH tunnel, **not** the remote Colab VM. Run **`stop.bat`** / `./down.sh`, use **Stop VM & Exit** in `launcher.bat`, or enable `AUTO_STOP_IDLE_MIN` so Compute Units stop being billed.
- **Google Drive Sync on Stop**: With the default `DRIVE_MODEL_CACHE=0`, stopping the VM syncs tuned presets in `<1s` and terminates immediately. If you enable `DRIVE_MODEL_CACHE=1` and a model backup is actively running when you stop, `down.sh` verifies the backup process is alive and waits (with a bounded timeout) before terminating the VM (press `Ctrl+C` to stop immediately).
- **Single SSH Connection Multiplexing**: Google Colab runtimes allow one active SSH WebSocket connection at a time. All scripts multiplex over a shared OpenSSH `ControlMaster` socket (`./ssh_config`). Always use `./ssh.sh` rather than `colab ssh` directly.

---

## Credits & Acknowledgments

This research project builds upon and credits the following open-source projects:

- **[Strata](https://github.com/Niko1221/Strata)** by **[@Niko1221](https://github.com/Niko1221)** ([MIT License](https://github.com/Niko1221/Strata/blob/main/LICENSE)) — The high-performance hybrid GPU/RAM inference engine and Strata Desktop application (`app/host`).
- **[Google Colab CLI (`google-colab-cli`)](https://github.com/googlecolab/google-colab-cli)** by **Google Colab** (Apache-2.0 License) — Command-line provisioning, Drive mounting, and SSH WebSocket tunneling for Google Colab runtimes.
- **[`strata-colab-cli`](https://github.com/NeviumX/strata-colab-cli)** by **[@NeviumX](https://github.com/NeviumX)** — Original inspiration for bridging Strata on Google Colab to Windows via WSL2 and SSH port forwarding.

---

## License

Released under the [MIT License](LICENSE).
