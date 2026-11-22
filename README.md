# Strata Colab Desktop

Run the full **[Strata Desktop Application](https://github.com/Niko1221/Strata)** (with **256K context**, **1-Click Hardware Auto-Tuning**, **Persistent Google Drive Model Caching**, and local **OpenAI / Anthropic API endpoints**) on a paid **Google Colab GPU** runtime (`G4 RTX PRO 6000 Blackwell`, `H100`, `A100`, `L4`, or `T4`) for personal interactive research, forwarded strictly to **`http://localhost:8080`** (`127.0.0.1`) on your local machine over the official Google Colab CLI SSH tunnel.

---

## Key Features

- **Full Strata Desktop UI (`UI_MODE=desktop`)**: Builds and runs Strata's complete desktop interface (`app/host`) directly on the Colab GPU VM — giving you Chat, Files & Workspace, Live Code Preview, the Models Manager, 1-Click Engine Auto-Tuning, Live GPU/RAM Telemetry, and OpenAI (`/v1`) & Anthropic (`/v1/messages`) API gateways at `http://localhost:8080`.
- **Native 256K Context (`CONTEXT=262144`)**: Configured out-of-the-box for Qwen3.8-Flash-Next's full 256K (`262,144` tokens) context window.
- **Interactive GPU Discovery & Smart Capacity Fallback**: Queries Google Colab for your account's compute unit balance and eligible GPUs (`G4`, `H100`, `A100`, `L4`, `T4`). Automatically handles single-shape high-memory GPUs (`G4` 98 GB VRAM / 176 GB RAM, `H100` 80 GB VRAM / 167 GB RAM, `L4` 23 GB VRAM / 52 GB RAM), cold-boot retries, and interactive fallback if a GPU pool returns `503 Service Unavailable`.
- **Persistent Google Drive Model Cache (`USE_DRIVE=1`)**:
  - Automatically mounts your Google Drive (`/content/drive/MyDrive/Strata-data`).
  - **Fast Local NVMe Restore**: Restores cached `.gguf` weights, `.done` SHA-256 verification markers, prepared `packs/`, and `dflash2/` drafter files onto the Colab VM's fast local NVMe SSD (`/content/Strata-data`) at Google datacenter transfer speeds — skipping both external Hugging Face downloads and multi-minute SHA-256 re-hashing.
  - **Automatic Background Backup**: Newly downloaded and verified models are backed up to Google Drive in the background (automatically pausing while GPU calibration benchmarks run).

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
colab usage
```

The first `colab usage` command prints a Google OAuth link — open it in your browser, sign in to your Google Colab account, and paste the authorization code into the terminal.

### 2. Launch Strata Desktop

On Windows, double-click **`start.bat`** (or run `./up.sh` inside WSL):

1. **Choose a GPU**: The script displays your Compute Unit balance and an interactive menu of eligible GPUs for your account:
   ```text
   Eligible GPUs for your Google Colab account:
       1) G4    (RTX PRO 6000 Blackwell: 98 GB VRAM / 176 GB RAM) [default]
       2) H100  (80 GB VRAM / ~167 GB RAM)
       3) A100  (40-80 GB VRAM / ~83-167 GB RAM)
       4) L4    (23 GB VRAM / 52 GB RAM)
       5) T4    (15 GB VRAM / 12.7-51 GB RAM)
   ```
2. **Authorize Google Drive (First Run Only)**: `colab drivemount` mounts `/content/drive` on the Colab VM so downloaded models are persisted across sessions.
3. **Choose a Model**: Models already saved in your Google Drive are automatically badged with `[Cached in Google Drive - fast start!]`:
   ```text
   Choose a Strata model to run (GPU: A100 / Context: 262144 tokens):
       1) Qwen3.6-35B-A3B  [UD-Q4_K_XL]  (22.9 GB download, ~4-5 min start, fits L4/T4)
       2) Qwen3.8-Flash    [IQ2_XS]      (~68 GB download, 35.5 GB RAM, recommended for L4 52GB)
       3) Qwen3.8-Flash    [Q2_0]        (~66 GB download, 34.0 GB RAM, fastest full Qwen3.8)
       4) Qwen3.8-Coder    [IQ1_M]       (~36 GB download, 23.0 GB RAM, coding specialist)
       5) Qwen3.8-Flash    [IQ3_S]       (~84 GB download, 50.0 GB RAM, best for G4/A100/H100) [default]
   ```
4. **Chat, Code & Tune**: Once ready, your browser opens **`http://localhost:8080`** to the full **Strata Desktop App**.

---

## Commands & Scripts

| Action | Windows | WSL / Linux |
|---|---|---|
| **Start runtime, mount Drive & open Strata Desktop** | `start.bat` | `./up.sh` |
| **Restart Strata after editing `config.env` (keeps VM & models)** | `restart.bat` | `./restart.sh` |
| **Stop runtime & stop compute unit billing** | `stop.bat` | `./down.sh` |
| **Check runtime, GPU, Drive cache & tunnel status** | `status.bat` | `./status.sh` |
| **Stream live remote logs** | | `./logs.sh` |
| **Open an interactive SSH shell on the Colab VM** | | `./ssh.sh` |
| **Reconnect the local SSH tunnel to a running VM** | | `./tunnel.sh` |

### Local Endpoints (while tunnel is active)

- **Strata Desktop UI**: `http://localhost:8080`
- **OpenAI-Compatible API**: `http://localhost:8080/v1`
- **Anthropic Messages API**: `http://localhost:8080/v1/messages`

---

## Configuration (`config.env`)

All defaults live in [`config.env`](config.env). For private tokens (`HF_TOKEN`, `API_KEY`) or local overrides, create a `config.local.env` file (automatically ignored by Git).

| Variable | Default | Description |
|---|---|---|
| `GPU` | `G4` | Preferred default GPU (`G4`, `H100`, `A100`, `L4`, `T4`) |
| `ASK_GPU` | `1` | Prompt to select an eligible GPU at startup and auto-fallback on `503` capacity shortages |
| `UI_MODE` | `desktop` | `desktop` = full Strata Desktop UI (`app/host`); `cli` = headless Strata CLI server |
| `MODEL` | `IQ3_S` | Default model quantization (`IQ3_S`, `IQ2_XS`, `Q2_0`, `IQ1_M`, `UD-Q4_K_XL`, etc.) |
| `ASK_MODEL` | `1` | Prompt to select a model matched to your GPU RAM and Google Drive cache |
| `CONTEXT` | `262144` | Context window size in tokens (`262144` = 256K tokens) |
| `TUNE_ON_START` | `0` | Set to `1` to automatically run Strata hardware calibration/tuning before loading |
| `USE_DRIVE` | `1` | Mount Google Drive to persist and restore models from `DRIVE_DATA_DIR` |
| `DRIVE_DATA_DIR` | `/content/drive/MyDrive/Strata-data` | Google Drive folder used for persistent model storage |
| `LOCAL_PORT` | `8080` | Local port on Windows / WSL forwarded to the Colab VM |

---

## Google Colab Terms of Service Compliance

This project is designed for personal interactive research in accordance with the [Google Colab Terms of Service](https://research.google.com/colaboratory/tos_v6.html) and [Google Colab FAQ](https://research.google.com/colaboratory/faq.html):

- **Paid Compute Units Required**: Per the Google Colab FAQ, remote SSH shells and interacting primarily through a WebUI instead of the notebook UI are disallowed on free runtimes without a positive compute unit balance. Maintain a positive paid compute unit balance (Colab Pro, Colab Pro+, or Pay-As-You-Go) when using this project.
- **Local-Only Personal Research (`127.0.0.1`)**: Port forwarding is bound strictly to `127.0.0.1` via Google's official `google-colab-cli` SSH tunnel for interactive personal research. Do **not** expose endpoints publicly (`0.0.0.0`, ngrok, Cloudflare tunnels, reverse proxies), run a web service offering, or share/resell access to third parties.
- **No Artificial Idle Bypass**: This project does not run dummy keep-alive loops to circumvent Google Colab idle timeouts, protecting both policy compliance and your compute unit balance. Always run `stop.bat` (`./down.sh`) when finished.

---

## Important Notes

- **Always Stop When Finished**: Closing the `start.bat` terminal window closes the local SSH tunnel, **not** the remote Colab VM. Run **`stop.bat`** (or `./down.sh`) when you are done so compute units stop being billed.
- **Google Drive Sync Protection on Stop**: If a newly downloaded model is still being backed up to Google Drive when you run `stop.bat`, the script waits for the Drive backup to finish before terminating the VM (press `Ctrl+C` if you want to abort the backup and stop immediately).
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
