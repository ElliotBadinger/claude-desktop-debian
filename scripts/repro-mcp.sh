#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/repro-mcp.sh [--duration SECONDS] [--output DIR]

Starts Claude Desktop with MCP_DEBUG=1, captures logs from the desktop app and
MCP processes, and packages everything into a tarball for troubleshooting.

Options:
  --duration SECONDS  Automatically stop capture after the given number of seconds.
                      Defaults to manual mode (press Enter to finish).
  --output DIR        Directory to write the repro bundle into. Defaults to
                      $XDG_STATE_HOME/claude-desktop/mcp/repro-<timestamp>.
  -h, --help          Show this help message.

Environment variables:
  CLAUDE_DESKTOP_COMMAND  Override the command used to launch Claude Desktop
                          (default: claude-desktop).
USAGE
}

DURATION=""
OUTPUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration)
      shift
      DURATION="${1:-}"
      if [[ -z "$DURATION" ]]; then
        echo "Error: --duration requires a value" >&2
        exit 1
      fi
      shift
      ;;
    --output)
      shift
      OUTPUT="${1:-}"
      if [[ -z "$OUTPUT" ]]; then
        echo "Error: --output requires a value" >&2
        exit 1
      fi
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/claude-desktop"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
SESSION_DIR="${OUTPUT:-$STATE_ROOT/mcp/repro-$TIMESTAMP}"
mkdir -p "$SESSION_DIR"

COMMAND="${CLAUDE_DESKTOP_COMMAND:-claude-desktop}"
APP_LOG="$SESSION_DIR/claude-desktop.log"
METADATA="$SESSION_DIR/metadata.txt"

echo "Creating MCP repro bundle at $SESSION_DIR"
{
  echo "timestamp=$(date -Iseconds)"
  echo "command=$COMMAND"
  if [[ -n "$DURATION" ]]; then
    echo "mode=duration"
    echo "duration_seconds=$DURATION"
  else
    echo "mode=manual"
  fi
} >"$METADATA"

if ! command -v "$COMMAND" >/dev/null 2>&1; then
  echo "Error: could not find '$COMMAND' on PATH" >&2
  exit 1
fi

echo "Starting Claude Desktop with MCP_DEBUG=1..."
MCP_DEBUG=1 "$COMMAND" >"$APP_LOG" 2>&1 &
APP_PID=$!

echo "app_pid=$APP_PID" >>"$METADATA"

echo "Claude Desktop started (PID $APP_PID)."
if [[ -n "$DURATION" ]]; then
  echo "Capturing logs for $DURATION seconds..."
  sleep "$DURATION"
else
  if [[ -t 0 ]]; then
    echo "Interact with the app, then press Enter to finish capture."
    read -r -p "Press Enter to stop..." _ || true
  else
    echo "No TTY available; defaulting to 60-second capture."
    sleep 60
  fi
fi

echo "Stopping Claude Desktop (PID $APP_PID)..."
if kill -0 "$APP_PID" 2>/dev/null; then
  kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
else
  echo "Process $APP_PID already exited." >>"$METADATA"
fi

# Capture process snapshot for reference
ps -eo pid,ppid,cmd | grep -i "mcp" | grep -v "grep" >"$SESSION_DIR/processes.txt" || true

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/Claude"
collect_file() {
  local src="$1"
  local dest="$2"
  if [[ -f "$src" ]]; then
    cp "$src" "$dest"
  fi
}

collect_dir() {
  local src="$1"
  local dest="$2"
  if [[ -d "$src" ]]; then
    mkdir -p "$dest"
    shopt -s nullglob dotglob
    for entry in "$src"/*; do
      local base="$(basename "$entry")"
      if [[ "$base" == "$(basename "$SESSION_DIR")" ]]; then
        continue
      fi
      cp -a "$entry" "$dest/" 2>/dev/null || true
    done
    shopt -u nullglob dotglob
  fi
}

collect_file "$HOME/claude-desktop-launcher.log" "$SESSION_DIR/claude-desktop-launcher.log"
collect_file "$CONFIG_DIR/claude_desktop_config.json" "$SESSION_DIR/claude_desktop_config.json"
collect_dir "$STATE_ROOT/mcp" "$SESSION_DIR/mcp-state"
collect_dir "$STATE_ROOT/logs" "$SESSION_DIR/app-state-logs"

# Record environment details helpful for debugging
{
  echo "PATH=$PATH"
  echo "SHELL=$SHELL"
  env | grep -E '^MCP_' || true
} >"$SESSION_DIR/environment.txt"

echo "Packaging logs..."
ARCHIVE="$SESSION_DIR.tar.gz"
tar -C "$(dirname "$SESSION_DIR")" -czf "$ARCHIVE" "$(basename "$SESSION_DIR")"

echo "Done. Bundle written to $ARCHIVE"
