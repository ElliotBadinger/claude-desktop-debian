#!/bin/bash
set -euo pipefail

# Arguments passed from the main script
VERSION="$1"
TARGET_ARCH="$2"  # amd64|arm64
WORK_DIR="$3" # The top-level build directory (e.g., ./build)
APP_STAGING_DIR="$4" # Directory containing the prepared app files (e.g., ./build/electron-app)
PACKAGE_NAME="$5"
MAINTAINER="$6"
DESCRIPTION="$7"
: "$MAINTAINER" "$DESCRIPTION"

echo "--- Starting RPM Package Build ---"
echo "Version: $VERSION"
echo "Target Arch: $TARGET_ARCH"
echo "Work Directory: $WORK_DIR"
echo "App Staging Directory: $APP_STAGING_DIR"
echo "Package Name: $PACKAGE_NAME"
echo "Maintainer: $MAINTAINER"
echo "Description: $DESCRIPTION"

# Map target arch to RPM arch
case "$TARGET_ARCH" in
  amd64) RPM_ARCH="x86_64" ;;
  arm64) RPM_ARCH="aarch64" ;;
  *) echo "❌ Unsupported target architecture: $TARGET_ARCH"; exit 1 ;;
esac
echo "RPM Arch: $RPM_ARCH"

# Validate staging contents
if [ ! -f "$APP_STAGING_DIR/app.asar" ]; then
  echo "❌ Missing app.asar in staging directory: $APP_STAGING_DIR"
  exit 1
fi
if [ ! -d "$APP_STAGING_DIR/app.asar.unpacked" ]; then
  echo "❌ Missing app.asar.unpacked in staging directory: $APP_STAGING_DIR"
  exit 1
fi

TOPDIR="$WORK_DIR/rpm"
mkdir -p "$TOPDIR/BUILD" "$TOPDIR/RPMS" "$TOPDIR/SOURCES" "$TOPDIR/SPECS" "$TOPDIR/SRPMS" "$TOPDIR/BUILDROOT"
SPECS="$TOPDIR/SPECS"

# Logging defaults (avoid unbound variable issues and capture rpmbuild logs)
LOG_DIR="${LOG_DIR:-"$WORK_DIR/logs"}"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_FILE:-"$LOG_DIR/rpmbuild.log"}"

# Reproducible builds: set SOURCE_DATE_EPOCH if not provided
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
  if command -v git >/dev/null 2>&1; then
    SOURCE_DATE_EPOCH="$(git log -1 --format=%ct 2>/dev/null || date -u +%s)"
  else
    SOURCE_DATE_EPOCH="$(date -u +%s)"
  fi
  export SOURCE_DATE_EPOCH
fi

# Generate SPEC file
SPEC_FILE="$SPECS/${PACKAGE_NAME}.spec"
echo "📝 Generating spec file at $SPEC_FILE"
# Disable nounset while writing heredoc to avoid accidental expansion errors if any variable-like tokens slip through
set +u
# shellcheck disable=SC2154
cat > "$SPEC_FILE" <<EOF
Name:           claude-desktop
Version:        %{version}
Release:        1%{?dist}
Summary:        ${DESCRIPTION}
Packager:       ${MAINTAINER}

License:        MIT and ASL 2.0
URL:            https://github.com/ElliotBadinger/claude-desktop-debian
ExclusiveArch:  x86_64 aarch64
Requires:       hicolor-icon-theme, desktop-file-utils

%description
${DESCRIPTION}

%prep
# No sources to unpack

%build
# Nothing to build

%install
rm -rf %{buildroot}
install -d %{buildroot}%{_libdir}/%{name}
install -d %{buildroot}%{_bindir}
install -d %{buildroot}%{_datadir}/applications

# Core application
cp -a %{stagingdir}/app.asar %{buildroot}%{_libdir}/%{name}/
cp -a %{stagingdir}/app.asar.unpacked %{buildroot}%{_libdir}/%{name}/
if [ -d "%{stagingdir}/node_modules" ]; then
  cp -a %{stagingdir}/node_modules %{buildroot}%{_libdir}/%{name}/
fi

# Launcher script
cat > %{buildroot}%{_bindir}/claude-desktop << 'EOS'
#!/bin/bash
set -e
LOG_FILE="${LOG_FILE:-$HOME/claude-desktop-launcher.log}"
echo "--- Claude Desktop Launcher Start ---" >> "$LOG_FILE"
echo "Timestamp: $(date)" >> "$LOG_FILE"
echo "Arguments: $@" >> "$LOG_FILE"

export ELECTRON_FORCE_IS_PACKAGED=true

IS_WAYLAND=false
if [ -n "$WAYLAND_DISPLAY" ]; then
  IS_WAYLAND=true
  echo "Wayland detected" >> "$LOG_FILE"
fi

ELECTRON_EXEC="electron"
LOCAL_ELECTRON_PATH_LIB64="/usr/lib64/claude-desktop/node_modules/electron/dist/electron"
LOCAL_ELECTRON_PATH_LIB="/usr/lib/claude-desktop/node_modules/electron/dist/electron"
if [ -f "$LOCAL_ELECTRON_PATH_LIB64" ]; then
  ELECTRON_EXEC="$LOCAL_ELECTRON_PATH_LIB64"
elif [ -f "$LOCAL_ELECTRON_PATH_LIB" ]; then
  ELECTRON_EXEC="$LOCAL_ELECTRON_PATH_LIB"
elif command -v electron > /dev/null; then
  ELECTRON_EXEC="$(command -v electron)"
else
  echo "Error: Electron executable not found (checked $LOCAL_ELECTRON_PATH_LIB64 and $LOCAL_ELECTRON_PATH_LIB)." >> "$LOG_FILE"
  exit 1
fi

APP_PATH_LIB64="/usr/lib64/claude-desktop/app.asar"
APP_PATH_LIB="/usr/lib/claude-desktop/app.asar"
if [ -f "$APP_PATH_LIB64" ]; then
  APP_PATH="$APP_PATH_LIB64"
else
  APP_PATH="$APP_PATH_LIB"
fi

ELECTRON_ARGS=("$APP_PATH")
if [ "$IS_WAYLAND" = true ]; then
  echo "Adding compatibility flags for Wayland session" >> "$LOG_FILE"
  ELECTRON_ARGS+=("--no-sandbox")
  ELECTRON_ARGS+=("--enable-features=UseOzonePlatform,WaylandWindowDecorations,GlobalShortcutsPortal")
  ELECTRON_ARGS+=("--ozone-platform=wayland")
  ELECTRON_ARGS+=("--enable-wayland-ime")
  ELECTRON_ARGS+=("--wayland-text-input-version=3")
fi

APP_DIR="$(dirname "$APP_PATH")"
echo "Changing directory to $APP_DIR" >> "$LOG_FILE"
cd "$APP_DIR" || { echo "Failed to cd to $APP_DIR" >> "$LOG_FILE"; exit 1; }

FINAL_CMD="\"$ELECTRON_EXEC\" \"\${ELECTRON_ARGS[@]}\" \"$@\""
echo "Executing: $FINAL_CMD" >> "$LOG_FILE"
"$ELECTRON_EXEC" "${ELECTRON_ARGS[@]}" "$@" >> "$LOG_FILE" 2>&1
EXIT_CODE=$?
echo "Electron exited with code: $EXIT_CODE" >> "$LOG_FILE"
echo "--- Claude Desktop Launcher End ---" >> "$LOG_FILE"
exit $EXIT_CODE
EOS
chmod 0755 %{buildroot}%{_bindir}/claude-desktop

# Desktop entry
cat > %{buildroot}%{_datadir}/applications/claude-desktop.desktop << 'EOD'
[Desktop Entry]
Name=Claude
Exec=/usr/bin/claude-desktop %u
Icon=claude-desktop
Type=Application
Terminal=false
Categories=Office;Utility;
MimeType=x-scheme-handler/claude;
StartupWMClass=Claude
EOD

# Icons
for size in 16 24 32 48 64 256; do
  install -d "%{buildroot}%{_datadir}/icons/hicolor/${size}x${size}/apps"
done
install -m 0644 "%{workdir}/claude_13_16x16x32.png" "%{buildroot}%{_datadir}/icons/hicolor/16x16/apps/claude-desktop.png" || true
install -m 0644 "%{workdir}/claude_11_24x24x32.png" "%{buildroot}%{_datadir}/icons/hicolor/24x24/apps/claude-desktop.png" || true
install -m 0644 "%{workdir}/claude_10_32x32x32.png" "%{buildroot}%{_datadir}/icons/hicolor/32x32/apps/claude-desktop.png" || true
install -m 0644 "%{workdir}/claude_8_48x48x32.png" "%{buildroot}%{_datadir}/icons/hicolor/48x48/apps/claude-desktop.png" || true
install -m 0644 "%{workdir}/claude_7_64x64x32.png" "%{buildroot}%{_datadir}/icons/hicolor/64x64/apps/claude-desktop.png" || true
install -m 0644 "%{workdir}/claude_6_256x256x32.png" "%{buildroot}%{_datadir}/icons/hicolor/256x256/apps/claude-desktop.png" || true

%post
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
fi
SANDBOX_PATH=""
if [ -f "/usr/lib64/claude-desktop/node_modules/electron/dist/chrome-sandbox" ]; then
  SANDBOX_PATH="/usr/lib64/claude-desktop/node_modules/electron/dist/chrome-sandbox"
elif [ -f "/usr/lib/claude-desktop/node_modules/electron/dist/chrome-sandbox" ]; then
  SANDBOX_PATH="/usr/lib/claude-desktop/node_modules/electron/dist/chrome-sandbox"
fi
if [ -n "$SANDBOX_PATH" ]; then
  chown root:root "$SANDBOX_PATH" || true
  chmod 4755 "$SANDBOX_PATH" || true
fi
exit 0

%postun
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
fi
exit 0

%files
%{_bindir}/claude-desktop
%{_datadir}/applications/claude-desktop.desktop
%{_datadir}/icons/hicolor/*/apps/claude-desktop.png
%{_libdir}/%{name}/app.asar
%{_libdir}/%{name}/app.asar.unpacked
%{_libdir}/%{name}/node_modules

%changelog
* Sat Sep 20 2025 Claude Desktop Linux Maintainers - %{version}-1
- Initial package build for Fedora

EOF
# Re-enable nounset after heredoc
set -u

echo "📦 Building RPM..."
# Pipe to tee while preserving failure with 'set -o pipefail' at script top
if ! rpmbuild -bb "$SPEC_FILE" \
    --define "_topdir $TOPDIR" \
    --define "version $VERSION" \
    --define "rpmarch $RPM_ARCH" \
    --define "stagingdir $APP_STAGING_DIR" \
    --define "workdir $WORK_DIR" \
    --define "_source_date_epoch $SOURCE_DATE_EPOCH" \
    --target "$RPM_ARCH" 2>&1 | tee "$LOG_FILE"; then
  echo "❌ rpmbuild failed. See log: $LOG_FILE"
  exit 1
fi

# Move resulting RPM next to work dir for build.sh to pick up
RPM_OUT=$(find "$TOPDIR/RPMS/$RPM_ARCH" -maxdepth 1 -name "${PACKAGE_NAME}-${VERSION}-1.*.rpm" | head -n 1 || true)
if [ -z "$RPM_OUT" ] || [ ! -f "$RPM_OUT" ]; then
  echo "❌ Failed to find built RPM in $TOPDIR/RPMS/$RPM_ARCH"
  exit 1
fi
cp -a "$RPM_OUT" "$WORK_DIR/"
echo "✓ RPM built at: $WORK_DIR/$(basename "$RPM_OUT")"
echo "--- RPM Package Build Finished ---"
exit 0
