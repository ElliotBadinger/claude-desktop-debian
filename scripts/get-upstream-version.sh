#!/usr/bin/env bash
set -euo pipefail

# Print latest upstream Claude Desktop version by inspecting the Windows installer payload.
# Outputs the version to stdout (e.g., 1.2.3). If $GITHUB_OUTPUT is set, also writes "version=..." to it.

# Dependencies: wget, 7z (p7zip)
need_cmd() {
  command -v "$1" &>/dev/null || {
    echo "❌ Required command '$1' not found in PATH" >&2
    exit 1
  }
}
need_cmd wget
need_cmd 7z

# Prefer x64 Windows installer; version is the same for arm64
CLAUDE_X64_URL="https://storage.googleapis.com/osprey-downloads-c02f6a0d-347c-492b-a752-3e0651722e97/nest-win-x64/Claude-Setup-x64.exe"

WORK_DIR="$(mktemp -d -t claude-ver-XXXXXX)"
# shellcheck disable=SC2317
cleanup() {
  # shellcheck disable=SC2317
  rm -rf "$WORK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

EXE_PATH="$WORK_DIR/Claude-Setup-x64.exe"

echo "📥 Downloading Claude Desktop installer (x64)..." >&2
if ! wget -q -O "$EXE_PATH" "$CLAUDE_X64_URL"; then
  echo "❌ Failed to download upstream Windows installer" >&2
  exit 1
fi

EXTRACT_DIR="$WORK_DIR/extract"
mkdir -p "$EXTRACT_DIR"

echo "📦 Extracting installer payload..." >&2
if ! 7z x -y "$EXE_PATH" -o"$EXTRACT_DIR" >/dev/null; then
  echo "❌ Failed to extract installer" >&2
  exit 1
fi

cd "$EXTRACT_DIR"
NUPKG_NAME="$(find . -maxdepth 1 -name 'AnthropicClaude-*.nupkg' | head -n 1 | sed 's|^\./||' || true)"
if [ -z "$NUPKG_NAME" ]; then
  echo "❌ Could not find AnthropicClaude-*.nupkg in extracted payload" >&2
  exit 1
fi

# Extract version from nupkg filename: AnthropicClaude-<ver>-full or -arm64-full
VERSION="$(echo "$NUPKG_NAME" | LC_ALL=C grep -oP 'AnthropicClaude-\K[0-9]+\.[0-9]+\.[0-9]+(?=-full|-arm64-full)')"
if [ -z "$VERSION" ]; then
  echo "❌ Failed to parse version from nupkg name: $NUPKG_NAME" >&2
  exit 1
fi

# Emit to stdout
echo "$VERSION"

# Also emit to GITHUB_OUTPUT for GitHub Actions if available
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "version=$VERSION" >> "$GITHUB_OUTPUT"
fi

exit 0
