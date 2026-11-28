#!/usr/bin/env bash
# ==============================================================================
# Coding-Agent Client Connection Helper (Claude Code, Cursor/Cline, OpenAI SDK)
# ==============================================================================
# Usage: ./connect.sh [claude|cursor|openai|all] [--apply] [--target <path>]
source "$(dirname "$0")/lib/common.sh"

LOCAL_PORT="${LOCAL_PORT:-8080}"
BASE_URL="http://localhost:$LOCAL_PORT"
OPENAI_BASE_URL="$BASE_URL/v1"
TOKEN_VAL="${API_KEY:-strata}"
MODEL_VAL="strata"

usage() {
    cat <<'EOF'
Usage: ./connect.sh [claude|cursor|openai|all] [--apply] [--target <path>]

Targets:
  claude    Print Claude Code (~/.claude/settings.json) config with KV-cache protection
  cursor    Print OpenAI-compatible config for Cursor / Cline / Continue / Roo Code
  openai    Print Python OpenAI SDK example snippet
  all       Print all client snippets (default)

Options:
  --apply          Merge Claude Code env keys safely into ~/.claude/settings.json
                   (creates a .bak backup first; requires target 'claude')
  --target <path>  Override settings.json destination path for --apply
  -h, --help       Show this help message
EOF
}

CLIENT=""
APPLY=0
TARGET_PATH="${HOME}/.claude/settings.json"

while (( $# > 0 )); do
    case "$1" in
        claude|cursor|openai|all)
            if [[ -n "$CLIENT" ]]; then
                echo "Error: multiple client targets specified ('$CLIENT' and '$1')." >&2
                usage >&2
                exit 2
            fi
            CLIENT="$1"
            shift
            ;;
        --apply)
            APPLY=1
            shift
            ;;
        --target)
            if (( $# < 2 )) || [[ -z "$2" ]]; then
                echo "Error: --target requires a file path argument." >&2
                usage >&2
                exit 2
            fi
            TARGET_PATH="$2"
            shift 2
            ;;
        --target=*)
            TARGET_PATH="${1#--target=}"
            if [[ -z "$TARGET_PATH" ]]; then
                echo "Error: --target requires a non-empty file path." >&2
                usage >&2
                exit 2
            fi
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: unknown argument '$1'." >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -z "$CLIENT" ]]; then
    CLIENT="all"
fi

if (( APPLY == 1 )) && [[ "$CLIENT" != "claude" ]]; then
    echo "Error: --apply is only supported with the 'claude' target (e.g. ./connect.sh claude --apply)." >&2
    exit 2
fi

print_claude() {
    cat <<EOF
=== Claude Code (~/.claude/settings.json) ===
Note: CLAUDE_CODE_ATTRIBUTION_HEADER="0" prevents per-request billing headers
      from invalidating Strata's prefix/KV cache on every turn.

{
  "env": {
    "ANTHROPIC_BASE_URL": "$BASE_URL",
    "ANTHROPIC_AUTH_TOKEN": "$TOKEN_VAL",
    "CLAUDE_CODE_ATTRIBUTION_HEADER": "0"
  }
}

Tip: Run './connect.sh claude --apply' to merge these env keys safely into
     ~/.claude/settings.json (with an automatic .bak backup).
EOF
}

print_cursor() {
    cat <<EOF
=== Cursor / Cline / Continue / Roo Code (OpenAI-Compatible) ===
Base URL  : $OPENAI_BASE_URL
API Key   : $TOKEN_VAL
Model ID  : $MODEL_VAL  (or the active model returned by GET $OPENAI_BASE_URL/models)

Anthropic Messages API Endpoint:
Base URL  : $BASE_URL

Continue (~/.continue/config.yaml) example:
models:
  - name: Strata Colab ($MODEL_VAL)
    provider: openai
    model: $MODEL_VAL
    apiBase: $OPENAI_BASE_URL
    apiKey: $TOKEN_VAL
EOF
}

print_openai() {
    cat <<EOF
=== Python OpenAI SDK ===
from openai import OpenAI

client = OpenAI(
    base_url="$OPENAI_BASE_URL",
    api_key="$TOKEN_VAL",
)

resp = client.chat.completions.create(
    model="$MODEL_VAL",
    messages=[{"role": "user", "content": "Hello from Strata on Google Colab!"}],
)
print(resp.choices[0].message.content)
EOF
}

apply_claude_settings() {
    require_cmds python3
    STRATA_TARGET_PATH="$TARGET_PATH" \
    STRATA_BASE_URL="$BASE_URL" \
    STRATA_AUTH_TOKEN="$TOKEN_VAL" \
    python3 - <<'PY'
import json
import os
import shutil
import sys
import tempfile

target = os.path.expanduser(os.environ["STRATA_TARGET_PATH"])
base_url = os.environ["STRATA_BASE_URL"]
auth_token = os.environ["STRATA_AUTH_TOKEN"]

parent = os.path.dirname(os.path.abspath(target))
os.makedirs(parent, exist_ok=True)

data = {}
backup_path = ""

if os.path.exists(target):
    with open(target, "r", encoding="utf-8") as fh:
        raw = fh.read()
    if raw.strip():
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError as exc:
            print(f"Error: existing file is not valid JSON ({target}): {exc}", file=sys.stderr)
            sys.exit(1)
        if not isinstance(parsed, dict):
            print(f"Error: expected a JSON object in {target}, got {type(parsed).__name__}.", file=sys.stderr)
            sys.exit(1)
        data = parsed
    backup_path = f"{target}.bak"
    shutil.copy2(target, backup_path)

env_map = data.get("env")
if env_map is None:
    env_map = {}
elif not isinstance(env_map, dict):
    print(f"Error: expected 'env' in {target} to be a JSON object, got {type(env_map).__name__}.", file=sys.stderr)
    sys.exit(1)

env_map["ANTHROPIC_BASE_URL"] = base_url
env_map["ANTHROPIC_AUTH_TOKEN"] = auth_token
env_map["CLAUDE_CODE_ATTRIBUTION_HEADER"] = "0"
data["env"] = env_map

fd, tmp_path = tempfile.mkstemp(prefix=".settings-", suffix=".tmp", dir=parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as out:
        json.dump(data, out, indent=2)
        out.write("\n")
    os.replace(tmp_path, target)
except Exception:
    try:
        os.unlink(tmp_path)
    except OSError:
        pass
    raise

if backup_path:
    print(f"Backed up existing settings to: {backup_path}")
print(f"Updated Claude Code settings: {target}")
print(f"  ANTHROPIC_BASE_URL             = {base_url}")
print(f"  CLAUDE_CODE_ATTRIBUTION_HEADER = 0")
print(f"  ANTHROPIC_AUTH_TOKEN           = {'strata' if auth_token == 'strata' else '<configured>'}")
PY
}

if (( APPLY == 1 )); then
    apply_claude_settings
    exit 0
fi

case "$CLIENT" in
    claude)
        print_claude
        ;;
    cursor)
        print_cursor
        ;;
    openai)
        print_openai
        ;;
    all)
        print_claude
        echo
        print_cursor
        echo
        print_openai
        ;;
esac
