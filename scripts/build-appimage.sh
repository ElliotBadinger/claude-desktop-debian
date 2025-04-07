#!/bin/bash
#
# build-appimage.sh - Creates an AppImage for Claude Desktop.
# Called by the main build.sh script.
#

# --- Strict Mode & Globals ---
set -euo pipefail # Use stricter error checking

# Arguments passed from the main script (assigned in main function)
VERSION=""
ARCHITECTURE=""
WORK_DIR=""
APP_STAGING_DIR=""
PACKAGE_NAME=""

# Derived paths and constants (assigned in setup_variables)
COMPONENT_ID="io.github.aaddrick.claude-desktop-debian" # Reverse DNS ID
APPDIR_PATH=""
APPIMAGETOOL_PATH=""
OUTPUT_PATH=""

# --- Helper Functions ---

# Print messages with color and formatting
_log() {
    local color_code="$1"
    shift
    # Use $'... ' quoting to ensure \033 is interpreted by bash before printf
    # Use %b to interpret escapes in the arguments ($*)
    printf $'\033[%sm%b\033[0m\n' "$color_code" "$*"
}
log_info()    { _log "0"    "INFO: $*"; }
log_warn()    { _log "1;33" "WARN: $*"; }
log_error()   { _log "1;31" "ERROR: $*"; } >&2 # Errors to stderr
log_success() { _log "1;32" "SUCCESS: $*"; }
log_step()    { _log "1;36" "\n--- $1 ---"; }

# Exit script with an error message
fail() {
    log_error "$@"
    exit 1
}

# --- Core Logic Functions ---

setup_variables_and_appdir() {
    log_step "Setup Variables & AppDir"
    APPDIR_PATH="$WORK_DIR/${COMPONENT_ID}.AppDir"
    OUTPUT_PATH="$WORK_DIR/${PACKAGE_NAME}-${VERSION}-${ARCHITECTURE}.AppImage"

    log_info "Component ID: $COMPONENT_ID"
    log_info "AppDir Path: $APPDIR_PATH"
    log_info "Output AppImage: $OUTPUT_PATH"

    log_info "Cleaning up previous AppDir (if any) at $APPDIR_PATH..."
    rm -rf "$APPDIR_PATH"

    log_info "Creating AppDir structure..."
    mkdir -p "$APPDIR_PATH/usr/bin"
    mkdir -p "$APPDIR_PATH/usr/lib"
    mkdir -p "$APPDIR_PATH/usr/share/icons/hicolor/256x256/apps" # For main icon
    mkdir -p "$APPDIR_PATH/usr/share/applications" # For bundled .desktop
    mkdir -p "$APPDIR_PATH/usr/share/metainfo" # For AppStream metadata
    log_success "✓ AppDir structure created."
}

stage_app_files() {
    log_step "Stage Application Files into AppDir"
    log_info "Copying core application files from $APP_STAGING_DIR..."

    # Explicitly copy required components
    if [ -f "$APP_STAGING_DIR/app.asar" ]; then
        cp -a "$APP_STAGING_DIR/app.asar" "$APPDIR_PATH/usr/lib/"
    else
        log_warn "app.asar not found in staging directory."
    fi

    if [ -d "$APP_STAGING_DIR/app.asar.unpacked" ]; then
        cp -a "$APP_STAGING_DIR/app.asar.unpacked" "$APPDIR_PATH/usr/lib/"
    else
        log_warn "app.asar.unpacked directory not found in staging directory."
    fi

    if [ -d "$APP_STAGING_DIR/node_modules" ]; then
        log_info "Copying node_modules (including Electron) from staging..."
        cp -a "$APP_STAGING_DIR/node_modules" "$APPDIR_PATH/usr/lib/"
    else
        fail "Packaged node_modules (including Electron) not found in staging dir $APP_STAGING_DIR. Cannot proceed."
    fi

    # Verify bundled Electron executable
    local bundled_electron_path="$APPDIR_PATH/usr/lib/node_modules/electron/dist/electron"
    log_info "Checking for bundled Electron executable at: $bundled_electron_path"
    if [ ! -x "$bundled_electron_path" ]; then
        fail "Electron executable not found or not executable in AppDir ($bundled_electron_path). Ensure it was copied correctly."
    fi
    # Ensure executable permission (should be preserved by cp -a, but double-check)
    chmod +x "$bundled_electron_path"
    log_success "✓ Application files staged and Electron verified."
}

create_apprun() {
    log_step "Create AppRun Script"
    local apprun_path="$APPDIR_PATH/AppRun"
    log_info "Creating AppRun script at $apprun_path..."

    cat << 'EOF' > "$apprun_path"
#!/bin/bash
set -e

# Find the location of the AppRun script
APPDIR=$(dirname "$0")

# --- Desktop Integration Handled by AppImageLauncher ---
# The bundled .desktop file provides MimeType for URI scheme.
# AppImageLauncher uses this for integration if chosen by the user.

# Set up environment variables if needed (e.g., LD_LIBRARY_PATH)
# export LD_LIBRARY_PATH="$APPDIR/usr/lib:$LD_LIBRARY_PATH"

# Detect if Wayland is likely running
IS_WAYLAND=false
if [ ! -z "$WAYLAND_DISPLAY" ]; then
  IS_WAYLAND=true
fi

# Path to the bundled Electron executable
ELECTRON_EXEC="$APPDIR/usr/lib/node_modules/electron/dist/electron"
APP_PATH="$APPDIR/usr/lib/app.asar"

# Base command arguments array
# Add --no-sandbox flag for AppImage compatibility
ELECTRON_ARGS=("--no-sandbox" "$APP_PATH")

# Add Wayland flags if Wayland is detected
if [ "$IS_WAYLAND" = true ]; then
  echo "AppRun: Wayland detected, adding flags."
  ELECTRON_ARGS+=("--enable-features=UseOzonePlatform,WaylandWindowDecorations" "--ozone-platform=wayland")
fi

# Define log file path in user's home directory
LOG_FILE="$HOME/claude-desktop-launcher.log"
echo "--- Claude Desktop AppImage Start ---" >> "$LOG_FILE"
echo "Timestamp: $(date)" >> "$LOG_FILE"
echo "AppDir: $APPDIR" >> "$LOG_FILE"
echo "Arguments: $@" >> "$LOG_FILE"

# Change to HOME directory before exec'ing Electron to avoid CWD permission issues
# Electron seems to prefer running from a user-writable directory.
cd "$HOME" || {
  echo "AppRun: Failed to cd to $HOME. Exiting." >> "$LOG_FILE";
  exit 1;
}
echo "AppRun: Changed working directory to $HOME" >> "$LOG_FILE"

# Execute Electron with app path, flags, and script arguments passed to AppRun
# Redirect stdout and stderr to the log file (append)
FINAL_CMD="$ELECTRON_EXEC ${ELECTRON_ARGS[@]} $@" # For logging
echo "AppRun: Executing: $FINAL_CMD" >> "$LOG_FILE"
exec "$ELECTRON_EXEC" "${ELECTRON_ARGS[@]}" "$@" >> "$LOG_FILE" 2>&1
EOF

    chmod +x "$apprun_path"
    log_success "✓ AppRun script created (with logging to \$HOME/claude-desktop-launcher.log, --no-sandbox, and CWD set to \$HOME)"
}

create_desktop_entry() {
    log_step "Create Bundled Desktop Entry"
    local desktop_file_name="${COMPONENT_ID}.desktop"
    local desktop_file_path_top="$APPDIR_PATH/$desktop_file_name"
    local desktop_file_path_usr="$APPDIR_PATH/usr/share/applications/$desktop_file_name"

    log_info "Creating bundled desktop entry for AppImage integration tools..."
    # Use printf for heredoc content
    printf '%s\n' \
        "[Desktop Entry]" \
        "Name=Claude" \
        "Exec=AppRun %u" \
        "Icon=$COMPONENT_ID" \
        "Type=Application" \
        "Terminal=false" \
        "Categories=Network;Utility;Office;" \
        "Comment=Claude Desktop for Linux" \
        "MimeType=x-scheme-handler/claude;" \
        "StartupWMClass=Claude" \
        "X-AppImage-Version=$VERSION" \
        "X-AppImage-Name=Claude Desktop" \
        > "$desktop_file_path_top"

    # Also place it in the standard location for tools like appimaged and validation
    cp "$desktop_file_path_top" "$desktop_file_path_usr"
    log_success "✓ Bundled desktop entry created at top-level and in usr/share/applications/"
}

copy_icons() {
    log_step "Copy Icons"
    local icon_source_path="$WORK_DIR/claude_6_256x256x32.png" # Use 256x256 icon

    if [ -f "$icon_source_path" ]; then
        log_info "Copying 256x256 icon ($icon_source_path)..."
        # Standard location within AppDir
        cp "$icon_source_path" "$APPDIR_PATH/usr/share/icons/hicolor/256x256/apps/${COMPONENT_ID}.png"
        # Top-level icon (used by appimagetool) - Should match the Icon field in the .desktop file
        cp "$icon_source_path" "$APPDIR_PATH/${COMPONENT_ID}.png"
        # Hidden .DirIcon (fallback for some systems/tools)
        cp "$icon_source_path" "$APPDIR_PATH/.DirIcon"
        log_success "✓ Icon copied to standard path, top-level, and .DirIcon"
    else
        log_warn "Missing 256x256 icon at $icon_source_path. AppImage icon might be missing."
    fi
}

create_appstream_metadata() {
    log_step "Create AppStream Metadata"
    local metadata_dir="$APPDIR_PATH/usr/share/metainfo"
    local appdata_file="$metadata_dir/${COMPONENT_ID}.appdata.xml" # Filename matches component ID

    log_info "Creating AppStream metadata file at $appdata_file..."
    # Use printf for heredoc content
    printf '%s\n' \
        '<?xml version="1.0" encoding="UTF-8"?>' \
        '<component type="desktop-application">' \
        "  <id>$COMPONENT_ID</id>" \
        '  <metadata_license>CC0-1.0</metadata_license>' \
        '  <project_license>MIT</project_license> <!-- Based on LICENSE-MIT -->' \
        '  <developer id="io.github.aaddrick">' \
        '    <name>aaddrick</name>' \
        '  </developer>' \
        '' \
        '  <name>Claude Desktop</name>' \
        '  <summary>Unofficial desktop client for Claude AI</summary>' \
        '' \
        '  <description>' \
        '    <p>' \
        '      Provides a desktop experience for interacting with Claude AI, wrapping the web interface.' \
        '    </p>' \
        '  </description>' \
        '' \
        "  <launchable type=\"desktop-id\">${COMPONENT_ID}.desktop</launchable>" \
        '' \
        "  <icon type=\"stock\">${COMPONENT_ID}</icon>" \
        '  <url type="homepage">https://github.com/aaddrick/claude-desktop-debian</url>' \
        '  <screenshots>' \
        '      <screenshot type="default">' \
        '          <image>https://github.com/user-attachments/assets/93080028-6f71-48bd-8e59-5149d148cd45</image>' \
        '      </screenshot>' \
        '  </screenshots>' \
        '  <provides>' \
        '    <binary>AppRun</binary>' \
        '  </provides>' \
        '' \
        '  <categories>' \
        '    <category>Network</category>' \
        '    <category>Utility</category>' \
        '    <category>Office</category>' \
        '  </categories>' \
        '' \
        '  <content_rating type="oars-1.1" />' \
        '' \
        '  <releases>' \
        "    <release version=\"$VERSION\" date=\"$(date +%Y-%m-%d)\">" \
        '      <description>' \
        "        <p>Version $VERSION.</p>" \
        '      </description>' \
        '    </release>' \
        '  </releases>' \
        '' \
        '</component>' \
        > "$appdata_file"
    log_success "✓ AppStream metadata created."
}

get_appimagetool() {
    log_step "Get appimagetool"
    APPIMAGETOOL_PATH="" # Reset just in case

    if command -v appimagetool &> /dev/null; then
        APPIMAGETOOL_PATH=$(command -v appimagetool)
        log_success "✓ Found appimagetool in PATH: $APPIMAGETOOL_PATH"
        return 0
    fi

    # Determine architecture for download URL
    local tool_arch=""
    case "$ARCHITECTURE" in # Use target ARCHITECTURE passed to script
        "amd64") tool_arch="x86_64" ;;
        "arm64") tool_arch="aarch64" ;;
        *) fail "Unsupported architecture for appimagetool download: $ARCHITECTURE" ;;
    esac

    local downloaded_tool_path="$WORK_DIR/appimagetool-${tool_arch}.AppImage"

    if [ -f "$downloaded_tool_path" ]; then
        APPIMAGETOOL_PATH="$downloaded_tool_path"
        chmod +x "$APPIMAGETOOL_PATH" # Ensure it's executable
        log_success "✓ Found previously downloaded appimagetool: $APPIMAGETOOL_PATH"
        return 0
    fi

    log_info "🛠️ Downloading appimagetool ($tool_arch)..."
    local appimagetool_url="https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-${tool_arch}.AppImage"

    if wget --quiet --show-progress -O "$downloaded_tool_path" "$appimagetool_url"; then
        chmod +x "$downloaded_tool_path"
        APPIMAGETOOL_PATH="$downloaded_tool_path"
        log_success "✓ Downloaded appimagetool to $APPIMAGETOOL_PATH"
    else
        log_error "Failed to download appimagetool from $appimagetool_url"
        rm -f "$downloaded_tool_path" # Clean up partial download
        fail "Cannot proceed without appimagetool."
    fi
}

build_appimage() {
    log_step "Build AppImage"
    if [ -z "$APPIMAGETOOL_PATH" ]; then
        fail "appimagetool path is not set. Cannot build AppImage."
    fi

    log_info "Building AppImage using $APPIMAGETOOL_PATH..."
    log_info "Source AppDir: $APPDIR_PATH"
    log_info "Output File: $OUTPUT_PATH"

    # Export ARCH environment variable required by appimagetool
    # Map build ARCHITECTURE to ARCH expected by appimagetool if needed (amd64->x86_64, arm64->aarch64)
    local tool_arch=""
     case "$ARCHITECTURE" in
        "amd64") tool_arch="x86_64" ;;
        "arm64") tool_arch="aarch64" ;;
        *) fail "Cannot map build architecture '$ARCHITECTURE' to appimagetool ARCH." ;;
    esac
    export ARCH="$tool_arch"
    log_info "Exporting ARCH=$ARCH for appimagetool"

    # Execute appimagetool
    if "$APPIMAGETOOL_PATH" "$APPDIR_PATH" "$OUTPUT_PATH"; then
        log_success "✓ AppImage built successfully: $OUTPUT_PATH"
    else
        fail "Failed to build AppImage using $APPIMAGETOOL_PATH"
    fi
}

# --- Main Execution ---

main() {
    # Assign arguments to global variables
    VERSION="${1?Version argument missing}"
    ARCHITECTURE="${2?Architecture argument missing}"
    WORK_DIR="${3?Work directory argument missing}"
    APP_STAGING_DIR="${4?App staging directory argument missing}"
    PACKAGE_NAME="${5?Package name argument missing}"

    log_info "--- Starting AppImage Build ---"
    log_info "Version: $VERSION"
    log_info "Architecture: $ARCHITECTURE"
    log_info "Work Directory: $WORK_DIR"
    log_info "App Staging Directory: $APP_STAGING_DIR"
    log_info "Package Name: $PACKAGE_NAME"

    setup_variables_and_appdir
    stage_app_files
    create_apprun
    create_desktop_entry
    copy_icons
    create_appstream_metadata
    get_appimagetool
    build_appimage

    log_info "--- AppImage Build Finished ---"
}

# Execute main function, passing all script arguments
main "$@"