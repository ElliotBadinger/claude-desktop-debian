#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/publish-dnf-repo.sh --rpm-dir <path> --repo-dir <path> [options]

Options:
  --repo-url <url>         Public base URL where the repo will be hosted. Used in generated .repo file.
  --signing-key-id <id>    Override the signing key ID. Defaults to $RPM_SIGNING_KEY_ID.
  --sync-dest <path|dest>  Optional rsync destination (local path or remote spec) to mirror the repo.
  --skip-sign              Skip signing packages and metadata (not recommended).
  --help                   Show this help and exit.
USAGE
}

ensure_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "❌ Missing required command: $1" >&2
    exit 1
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RPM_DIR=""
REPO_DIR=""
REPO_URL=""
SYNC_DEST=""
SIGNING_KEY_ID="${RPM_SIGNING_KEY_ID:-}"
SKIP_SIGN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rpm-dir)
      RPM_DIR="$2"
      shift 2
      ;;
    --repo-dir)
      REPO_DIR="$2"
      shift 2
      ;;
    --repo-url)
      REPO_URL="$2"
      shift 2
      ;;
    --signing-key-id)
      SIGNING_KEY_ID="$2"
      shift 2
      ;;
    --sync-dest)
      SYNC_DEST="$2"
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

if [[ -z "$RPM_DIR" || -z "$REPO_DIR" ]]; then
  echo "❌ --rpm-dir and --repo-dir are required." >&2
  usage >&2
  exit 1
fi

RPM_DIR="$(cd "$RPM_DIR" && pwd)"
mkdir -p "$REPO_DIR"
REPO_DIR="$(cd "$REPO_DIR" && pwd)"

if [[ ! -d "$RPM_DIR" ]]; then
  echo "❌ RPM directory $RPM_DIR does not exist" >&2
  exit 1
fi

ensure_cmd rpm
ensure_cmd createrepo_c
if [[ -n "$SYNC_DEST" ]]; then
  ensure_cmd rsync
fi
if ! $SKIP_SIGN; then
  ensure_cmd gpg
fi

mapfile -t RPM_FILES < <(find "$RPM_DIR" -type f -name '*.rpm' -print0 | sort -z | xargs -0 -r -n1 echo)
if [[ ${#RPM_FILES[@]} -eq 0 ]]; then
  echo "❌ No RPMs found in $RPM_DIR" >&2
  exit 1
fi

declare -A ARCH_DIRS=()

declare -a TEMP_DIRS=()
cleanup() {
  for dir in "${TEMP_DIRS[@]}"; do
    [[ -e "$dir" ]] && rm -rf "$dir"
  done
}
trap cleanup EXIT

setup_gpg() {
  if $SKIP_SIGN; then
    return
  fi

  if [[ -z "$SIGNING_KEY_ID" ]]; then
    echo "❌ Signing key ID is required. Set RPM_SIGNING_KEY_ID or pass --signing-key-id." >&2
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
    echo "❌ Could not find private key for $SIGNING_KEY_ID." >&2
    exit 1
  fi
}

sign_repodata() {
  local repo_path="$1"
  if $SKIP_SIGN; then
    echo "⚠️  Skipping metadata signing for $repo_path"
    return
  fi

  local repomd="$repo_path/repodata/repomd.xml"
  if [[ ! -f "$repomd" ]]; then
    echo "⚠️  repomd.xml not found in $repo_path; skipping signature" >&2
    return
  fi

  gpg --batch --yes --armor --detach-sign --output "$repomd.asc" "$repomd"
  sha256sum "$repomd" > "$repomd.sha256"
}

setup_gpg

export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$PROJECT_ROOT" log -1 --format=%ct 2>/dev/null || date -u +%s)}"
export TZ=UTC
umask 0022

touch "$REPO_DIR/.nojekyll"

for rpm_file in "${RPM_FILES[@]}"; do
  arch="$(rpm -qp --queryformat '%{ARCH}' "$rpm_file")"
  if [[ -z "$arch" ]]; then
    echo "⚠️  Unable to determine architecture for $rpm_file; skipping" >&2
    continue
  fi
  arch_dir="$REPO_DIR/$arch"
  mkdir -p "$arch_dir"
  install -m 0644 "$rpm_file" "$arch_dir/$(basename "$rpm_file")"
  ARCH_DIRS["$arch"]=1
  echo "📦 Copied $(basename "$rpm_file") to $arch_dir"
done

for arch in "${!ARCH_DIRS[@]}"; do
  arch_dir="$REPO_DIR/$arch"
  echo "🛠️  Updating metadata for $arch_dir"
  createrepo_c --update --simple-md-filenames --retain-old-md 5 "$arch_dir"
  sign_repodata "$arch_dir"
done

if ! $SKIP_SIGN; then
  PUBLIC_KEY_PATH="$REPO_DIR/RPM-GPG-KEY-claude-desktop"
  gpg --batch --yes --armor --export "$SIGNING_KEY_ID" > "$PUBLIC_KEY_PATH"
  echo "🔑 Exported public key to $PUBLIC_KEY_PATH"
fi

if [[ -n "$REPO_URL" ]]; then
  cat >"$REPO_DIR/claude-desktop.repo" <<EOF
[claude-desktop]
name=Claude Desktop DNF Repository
baseurl=${REPO_URL}/\$basearch/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=${REPO_URL}/RPM-GPG-KEY-claude-desktop
metadata_expire=6h
EOF
  echo "📝 Generated repo file at $REPO_DIR/claude-desktop.repo"
fi

if [[ -n "$SYNC_DEST" ]]; then
  if [[ "$SYNC_DEST" == *:* ]]; then
    echo "🔁 Rsync to remote destination $SYNC_DEST"
    rsync -av --delete "$REPO_DIR/" "$SYNC_DEST"
  else
    mkdir -p "$SYNC_DEST"
    local_dest="${SYNC_DEST%/}/"
    echo "🔁 Rsync to local destination $local_dest"
    rsync -av --delete "$REPO_DIR/" "$local_dest"
  fi
fi

echo "✅ Repository metadata updated in $REPO_DIR"
