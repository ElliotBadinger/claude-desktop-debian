#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/build-rpm.sh --version <version> [options]

Options:
  --arch <amd64|arm64>    Build only the specified architecture. May be repeated.
  --output-dir <path>     Directory where signed RPMs will be written. Defaults to ./dist/rpm.
  --signing-key-id <id>   Override the signing key ID. Defaults to $RPM_SIGNING_KEY_ID.
  --skip-sign             Build packages without signing them (intended for local testing).
  --help                  Show this message and exit.
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION=""
OUTPUT_DIR="$PROJECT_ROOT/dist/rpm"
ARCHES=()
SIGNING_KEY_ID="${RPM_SIGNING_KEY_ID:-}"
SKIP_SIGN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2
      ;;
    --arch)
      ARCHES+=("$2")
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --signing-key-id)
      SIGNING_KEY_ID="$2"
      shift 2
      ;;
    --skip-sign)
      SKIP_SIGN=true
      shift
      ;;
    --help|-h)
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

if [[ -z "$VERSION" ]]; then
  if [[ -x "$PROJECT_ROOT/scripts/get-upstream-version.sh" ]]; then
    VERSION="$("$PROJECT_ROOT/scripts/get-upstream-version.sh")"
  fi
fi

if [[ -z "$VERSION" ]]; then
  echo "❌ Unable to determine version. Pass --version <version>." >&2
  exit 1
fi

if [[ ${#ARCHES[@]} -eq 0 ]]; then
  ARCHES=(amd64 arm64)
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

declare -a TEMP_DIRS=()
cleanup() {
  for dir in "${TEMP_DIRS[@]}"; do
    [[ -d "$dir" ]] && rm -rf "$dir"
  done
}
trap cleanup EXIT

setup_gpg() {
  if $SKIP_SIGN; then
    return
  fi

  if [[ -z "$SIGNING_KEY_ID" ]]; then
    echo "❌ RPM signing is required but no signing key ID was provided." >&2
    echo "   Set RPM_SIGNING_KEY_ID or pass --signing-key-id." >&2
    exit 1
  fi

  GNUPGHOME="$(mktemp -d)"
  chmod 700 "$GNUPGHOME"
  export GNUPGHOME
  TEMP_DIRS+=("$GNUPGHOME")

  if [[ -n "${RPM_SIGNING_KEY_BASE64:-}" ]]; then
    KEY_FILE="$(mktemp)"
    TEMP_DIRS+=("$KEY_FILE")
    echo "$RPM_SIGNING_KEY_BASE64" | base64 --decode > "$KEY_FILE"
    gpg --batch --import "$KEY_FILE" >/dev/null 2>&1
  fi

  if ! gpg --batch --list-secret-keys "$SIGNING_KEY_ID" >/dev/null 2>&1; then
    echo "❌ Could not find a private key for ID $SIGNING_KEY_ID in the temporary keyring." >&2
    echo "   Ensure RPM_SIGNING_KEY_BASE64 contains the ASCII-armored private key." >&2
    exit 1
  fi
}

sign_rpm() {
  local rpm_path="$1"
  if $SKIP_SIGN; then
    echo "⚠️  Signing skipped for $rpm_path"
    return
  fi
  if ! command -v rpmsign >/dev/null 2>&1; then
    echo "❌ rpmsign not available in PATH." >&2
    exit 1
  fi

  local macros_file
  macros_file="$(mktemp)"
  TEMP_DIRS+=("$macros_file")

  local pass_macro=""
  if [[ -n "${RPM_SIGNING_PASSPHRASE:-}" ]]; then
    local pass_file
    pass_file="$(mktemp)"
    TEMP_DIRS+=("$pass_file")
    printf '%s' "$RPM_SIGNING_PASSPHRASE" >"$pass_file"
    pass_macro="--passphrase-file $pass_file"
  fi

  cat >"$macros_file" <<EOF
%_signature gpg
%_gpg_name ${SIGNING_KEY_ID}
%_gpg_path ${GNUPGHOME}
%__gpg gpg
%__gpg_sign_cmd %{__gpg} --batch --pinentry-mode loopback ${pass_macro} --no-armor --detach-sign --sign %{-u*} %{-s*} %{__signdata}
EOF

  echo "🔏 Signing $(basename "$rpm_path") with key $SIGNING_KEY_ID"
  rpmsign --macros "$macros_file" --addsign "$rpm_path"
  rpm --checksig "$rpm_path"
}

setup_gpg

export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$PROJECT_ROOT" log -1 --format=%ct 2>/dev/null || date -u +%s)}"
export TZ=UTC
umask 0022

for arch in "${ARCHES[@]}"; do
  case "$arch" in
    amd64|arm64) ;;
    *)
      echo "❌ Unsupported architecture: $arch" >&2
      exit 1
      ;;
  esac

  echo "🚧 Building RPM for $arch (version $VERSION)"
  find "$PROJECT_ROOT" -maxdepth 1 -name 'claude-desktop-*.rpm' -delete

  pushd "$PROJECT_ROOT" >/dev/null
  chmod +x ./build.sh
  ./build.sh --build rpm --clean yes --target-arch "$arch"
  popd >/dev/null

  rpm_file="$(find "$PROJECT_ROOT" -maxdepth 1 -name "claude-desktop-${VERSION}-1.*.rpm" | head -n 1 || true)"
  if [[ -z "$rpm_file" || ! -f "$rpm_file" ]]; then
    echo "❌ Expected RPM claude-desktop-${VERSION}-1.*.rpm was not produced" >&2
    exit 1
  fi

  arch_dir="$OUTPUT_DIR/$arch"
  mkdir -p "$arch_dir"
  dest="$arch_dir/$(basename "$rpm_file")"
  mv "$rpm_file" "$dest"

  sign_rpm "$dest"

  echo "✅ Built $(basename "$dest")"
done

echo "All RPMs written to $OUTPUT_DIR"
