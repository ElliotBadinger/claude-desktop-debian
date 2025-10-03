#!/usr/bin/env bash
set -euo pipefail

OWNER="${CLAUDE_OWNER:-ElliotBadinger}"
REPO="${CLAUDE_REPO:-claude-desktop-debian}"
API_BASE="https://api.github.com/repos/${OWNER}/${REPO}"
ALT_OWNER="${CLAUDE_FALLBACK_OWNER:-aaddrick}"

usage() { cat <<'EOF'
Usage: install.sh [--update-only] [--no-timer]
  --update-only  Attempt to update existing installation; on failure, clean reinstall.
  --no-timer     Do not install/enable auto-update timer.
EOF
}

UPDATE_ONLY=0
INSTALL_TIMER=1
DRY_RUN="${CLAUDE_DRY_RUN:-0}"
while [[ ${1:-} ]]; do
  case "$1" in
    --update-only) UPDATE_ONLY=1 ;;
    --no-timer) INSTALL_TIMER=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1"; exit 1; }; }
need_cmd curl
need_cmd uname

is_root() { [[ ${EUID:-$(id -u)} -eq 0 ]]; }
SUDO=""
if ! is_root; then
  if [[ "${DRY_RUN:-0}" = "1" ]]; then
    # In dry-run mode, do not require sudo/root
    SUDO=""
  elif command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "This script requires root privileges for package installation."
    exit 1
  fi
fi

log() { echo -e "[install] $*"; }

detect_arch() {
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "unsupported";;
  esac
}

detect_pkg_mgr() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck source=/etc/os-release
    . /etc/os-release
    local id="${ID:-}"; local like="${ID_LIKE:-}"
    if [[ "$id" =~ (debian|ubuntu|linuxmint) ]] || [[ "$like" =~ (debian|ubuntu) ]]; then echo "apt"; return; fi
    if [[ "$id" =~ (fedora|rhel|centos|rocky|alma) ]] || [[ "$like" =~ (rhel|fedora) ]]; then echo "dnf"; return; fi
  fi
  echo "appimage"
}

fedora_version() {
  # shellcheck source=/etc/os-release
  . /etc/os-release 2>/dev/null || true
  local version="${VERSION_ID:-40}"
  echo "$version" | cut -d. -f1
}

get_latest_release_json() {
  # Try primary repo; if it doesn't look like a valid release payload, fall back to ALT_OWNER
  local primary
  primary=$(curl -fsSL -H "Accept: application/vnd.github+json" "${API_BASE}/releases/latest" || true)
  if echo "$primary" | grep -q '"tag_name"'; then
    echo "$primary"
    return
  fi
  curl -fsSL -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${ALT_OWNER}/${REPO}/releases/latest"
}

json_find_asset_url() {
  # args: regex-pattern
  local pattern="$1"
  grep -oE '"browser_download_url": "[^"]+"' | sed -E 's/^"browser_download_url": "([^"]+)".*/\1/' | grep -E "$pattern" | head -n1
}

download_to() {
  local url="$1"; local out="$2"
  log "Downloading $url"
  curl -fL --retry 3 --retry-delay 2 -o "$out" "$url"
}

install_deb() {
  local url="$1"
  if [[ "$DRY_RUN" = "1" ]]; then
    log "DRY RUN: would download and install DEB from $url"
    return 0
  fi
  local tmp
  tmp="$(mktemp -d)"
  local file="$tmp/claude.deb"
  download_to "$url" "$file"
  $SUDO dpkg -i "$file" || { $SUDO apt-get -y -f install; $SUDO dpkg -i "$file"; }
  rm -rf "$tmp"
}

install_rpm() {
  local url="$1"
  if [[ "$DRY_RUN" = "1" ]]; then
    log "DRY RUN: would install RPM from $url"
    return 0
  fi
  if command -v dnf >/dev/null 2>&1; then
    $SUDO dnf -y install "$url"
  else
    $SUDO yum -y install "$url"
  fi
}

install_appimage() {
  local url="$1"
  if [[ "$DRY_RUN" = "1" ]]; then
    log "DRY RUN: would install AppImage from $url and create launcher script/desktop entry"
    return 0
  fi
  local dir="/opt/claude-desktop"
  local bin="/usr/local/bin/claude-desktop"
  local appimage="$dir/claude-desktop.AppImage"
  $SUDO mkdir -p "$dir"
  local tmp
  tmp="$(mktemp -d)"
  download_to "$url" "$tmp/claude.AppImage"
  $SUDO install -m 0755 "$tmp/claude.AppImage" "$appimage"
  rm -rf "$tmp"
  # wrapper
  echo "#!/usr/bin/env bash" | $SUDO tee "$bin" >/dev/null
  echo "exec \"$appimage\" \"\$@\"" | $SUDO tee -a "$bin" >/dev/null
  $SUDO chmod +x "$bin"
  # desktop entry
  local desktop="/usr/share/applications/claude-desktop.desktop"
  cat <<DESK | $SUDO tee "$desktop" >/dev/null
[Desktop Entry]
Name=Claude Desktop
Comment=Anthropic Claude Desktop
Exec=$bin
Icon=claude-desktop
Terminal=false
Type=Application
Categories=Utility;Office;
DESK
}

uninstall_pkg() {
  if [[ "$DRY_RUN" = "1" ]]; then
    log "DRY RUN: would uninstall existing Claude Desktop from system (deb/rpm/appimage paths)"
    return 0
  fi
  if dpkg -s claude-desktop >/dev/null 2>&1; then
    $SUDO apt-get -y remove claude-desktop || $SUDO dpkg -r claude-desktop || true
    $SUDO apt-get -y autoremove || true
    return
  fi
  if rpm -q claude-desktop >/dev/null 2>&1; then
    if command -v dnf >/dev/null 2>&1; then $SUDO dnf -y remove claude-desktop || true; else $SUDO yum -y remove claude-desktop || true; fi
    return
  fi
  # AppImage fallback uninstall
  $SUDO rm -f /usr/local/bin/claude-desktop /usr/share/applications/claude-desktop.desktop || true
  $SUDO rm -rf /opt/claude-desktop || true
}

setup_auto_update() {
  if [[ "$DRY_RUN" = "1" ]]; then
    log "DRY RUN: would install auto-update helper and configure systemd timer or cron"
    return 0
  fi
  local updater="/usr/local/bin/claude-desktop-update"
  cat <<'UPD' | $SUDO tee "$updater" >/dev/null
#!/usr/bin/env bash
set -euo pipefail
OWNER="${CLAUDE_OWNER:-ElliotBadinger}"
REPO="${CLAUDE_REPO:-claude-desktop-debian}"
curl -fsSL "https://raw.githubusercontent.com/${OWNER}/${REPO}/main/install.sh" | bash -s -- --update-only --no-timer
UPD
  $SUDO chmod +x "$updater"

  if command -v systemctl >/dev/null 2>&1; then
    local svc="/etc/systemd/system/claude-desktop-update.service"
    local tim="/etc/systemd/system/claude-desktop-update.timer"
    cat <<'SVC' | $SUDO tee "$svc" >/dev/null
[Unit]
Description=Update Claude Desktop

[Service]
Type=oneshot
ExecStart=/usr/local/bin/claude-desktop-update
SVC
    cat <<'TMR' | $SUDO tee "$tim" >/dev/null
[Unit]
Description=Run Claude Desktop updater daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
TMR
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable --now claude-desktop-update.timer
    log "Enabled systemd timer 'claude-desktop-update.timer'"
  else
    local cron="/etc/cron.daily/claude-desktop-update"
    cat <<'CRON' | $SUDO tee "$cron" >/dev/null
#!/usr/bin/env bash
/usr/local/bin/claude-desktop-update >/var/log/claude-desktop-update.log 2>&1
CRON
    $SUDO chmod +x "$cron"
    log "Installed cron.daily entry for auto-update"
  fi
}

perform_install() {
  local mgr="$1"; local arch="$2"
  log "Package manager: $mgr, arch: $arch"
  local json
  json="$(get_latest_release_json)"
  local url=""
  if [[ "$mgr" == "apt" ]]; then
    url="$(echo "$json" | json_find_asset_url "claude-desktop_.*_${arch}\\.deb")"
    if [[ -z "$url" ]]; then url="$(echo "$json" | json_find_asset_url "\\.deb$")"; fi
    if [[ -z "$url" ]]; then
      log "No .deb asset found; falling back to AppImage"
      # AppImage fallback for apt path
      url="$(echo "$json" | json_find_asset_url "\\.AppImage$")"
      if [[ -z "$url" ]]; then echo "No AppImage asset found"; return 1; fi
      install_appimage "$url"
      return 0
    fi
    install_deb "$url"
    return 0
  fi
  if [[ "$mgr" == "dnf" ]]; then
    local fv
    fv="$(fedora_version)"
    local rpm_arch
    if [[ "$arch" == "amd64" ]]; then rpm_arch="x86_64"; else rpm_arch="aarch64"; fi
    url="$(echo "$json" | json_find_asset_url "claude-desktop-.*\\.fc${fv}\\.${rpm_arch}\\.rpm")"
    if [[ -z "$url" ]]; then url="$(echo "$json" | json_find_asset_url "\\.${rpm_arch}\\.rpm$")"; fi
    if [[ -z "$url" ]]; then
      log "No .rpm asset found; falling back to AppImage"
      # AppImage fallback for dnf path
      url="$(echo "$json" | json_find_asset_url "\\.AppImage$")"
      if [[ -z "$url" ]]; then echo "No AppImage asset found"; return 1; fi
      install_appimage "$url"
      return 0
    fi
    install_rpm "$url"
    return 0
  fi
  # AppImage fallback
  url="$(echo "$json" | json_find_asset_url "\\.AppImage$")"
  if [[ -z "$url" ]]; then echo "No AppImage asset found"; return 1; fi
  install_appimage "$url"
}

try_update_with_fallback() {
  local mgr="$1"
  local arch="$2"
  if perform_install "$mgr" "$arch"; then
    log "Install/Update completed"
    return 0
  fi
  log "Primary install/update failed; attempting clean reinstall"
  uninstall_pkg || true
  perform_install "$mgr" "$arch"
}

main() {
  local arch
  arch="$(detect_arch)"
  if [[ "$arch" == "unsupported" ]]; then echo "Unsupported architecture $(uname -m)"; exit 1; fi
  local mgr
  mgr="$(detect_pkg_mgr)"
  log "Detected: mgr=$mgr arch=$arch"

  if [[ "$UPDATE_ONLY" -eq 1 ]]; then
    try_update_with_fallback "$mgr" "$arch"
  else
    try_update_with_fallback "$mgr" "$arch"
  fi

  if [[ "$INSTALL_TIMER" -eq 1 ]]; then
    setup_auto_update
  else
    log "Auto-update timer installation skipped (--no-timer)"
  fi

  log "Done."
}

main "$@"
