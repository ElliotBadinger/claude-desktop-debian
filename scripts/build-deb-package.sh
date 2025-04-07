#!/bin/bash
#
# build-deb-package.sh - Creates a .deb package for Claude Desktop.
# Called by the main build.sh script.
#

# --- Strict Mode & Globals ---
set -euo pipefail

# Arguments passed from the main script (assigned in main function)
VERSION=""
ARCHITECTURE=""
WORK_DIR=""
APP_STAGING_DIR=""
PACKAGE_NAME=""
MAINTAINER=""
DESCRIPTION=""

# Derived paths (assigned in setup_variables)
PACKAGE_ROOT=""
INSTALL_DIR=""
DEB_FILE=""

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

setup_variables_and_dirs() {
    log_step "Setup Variables & Directories"
    PACKAGE_ROOT="$WORK_DIR/package"
    INSTALL_DIR="$PACKAGE_ROOT/usr"
    DEB_FILE="$WORK_DIR/${PACKAGE_NAME}_${VERSION}_${ARCHITECTURE}.deb"

    log_info "Package Root: $PACKAGE_ROOT"
    log_info "Install Dir: $INSTALL_DIR"
    log_info "Output Deb File: $DEB_FILE"

    # Clean previous package structure if it exists
    log_info "Cleaning up previous package structure (if any) in $PACKAGE_ROOT..."
    rm -rf "$PACKAGE_ROOT"

    # Create Debian package structure
    log_info "Creating package structure..."
    mkdir -p "$PACKAGE_ROOT/DEBIAN"
    mkdir -p "$INSTALL_DIR/lib/$PACKAGE_NAME"
    mkdir -p "$INSTALL_DIR/share/applications"
    # Icons are installed into specific size dirs later
    mkdir -p "$INSTALL_DIR/bin"
    log_success "✓ Package structure created."
}

install_icons() {
    log_step "Icon Installation"
    # Map icon sizes to their corresponding extracted files (relative to WORK_DIR)
    declare -A icon_files=(
        ["16"]="claude_13_16x16x32.png"
        ["24"]="claude_11_24x24x32.png"
        ["32"]="claude_10_32x32x32.png"
        ["48"]="claude_8_48x48x32.png"
        ["64"]="claude_7_64x64x32.png"
        ["256"]="claude_6_256x256x32.png"
    )

    for size in 16 24 32 48 64 256; do
        local icon_dir="$INSTALL_DIR/share/icons/hicolor/${size}x${size}/apps"
        mkdir -p "$icon_dir"
        local icon_source_path="$WORK_DIR/${icon_files[$size]}"
        if [ -f "$icon_source_path" ]; then
            log_info "Installing ${size}x${size} icon from $icon_source_path..."
            # Use install command for setting permissions and creating dirs
            install -Dm 644 "$icon_source_path" "$icon_dir/claude-desktop.png"
        else
            log_warn "Missing ${size}x${size} icon at $icon_source_path"
        fi
    done
    log_success "✓ Icons installed."
}

copy_app_files() {
    log_step "Copy Application Files"
    log_info "Copying application files from $APP_STAGING_DIR..."
    cp "$APP_STAGING_DIR/app.asar" "$INSTALL_DIR/lib/$PACKAGE_NAME/"
    # Check if unpacked dir exists before copying
    if [ -d "$APP_STAGING_DIR/app.asar.unpacked" ]; then
         cp -r "$APP_STAGING_DIR/app.asar.unpacked" "$INSTALL_DIR/lib/$PACKAGE_NAME/"
    else
        log_warn "app.asar.unpacked directory not found in staging. Skipping copy."
    fi

    # Copy local electron (always packaged now)
    if [ -d "$APP_STAGING_DIR/node_modules/electron" ]; then
        log_info "Copying packaged electron..."
        cp -r "$APP_STAGING_DIR/node_modules" "$INSTALL_DIR/lib/$PACKAGE_NAME/"
    else
         log_warn "Packaged electron node_modules not found in staging dir $APP_STAGING_DIR. This might be an error."
    fi
    log_success "✓ Application files copied."
}

create_desktop_entry() {
    log_step "Create Desktop Entry"
    local desktop_file="$INSTALL_DIR/share/applications/claude-desktop.desktop"
    log_info "Creating desktop entry at $desktop_file..."
    # Use printf for heredoc content
    printf '%s\n' \
        "[Desktop Entry]" \
        "Name=Claude" \
        "Exec=/usr/bin/claude-desktop %u" \
        "Icon=claude-desktop" \
        "Type=Application" \
        "Terminal=false" \
        "Categories=Office;Utility;Network;" \
        "MimeType=x-scheme-handler/claude;" \
        "StartupWMClass=Claude" \
        > "$desktop_file"
    log_success "✓ Desktop entry created."
}

create_launcher_script() {
    log_step "Create Launcher Script"
    local launcher_path="$INSTALL_DIR/bin/claude-desktop"
    log_info "Creating launcher script at $launcher_path..."
    # Use printf for heredoc content, ensure proper escaping for shell variables inside
    printf '%s\n' \
        '#!/bin/bash' \
        '' \
        'LOG_FILE="$HOME/claude-desktop-launcher.log"' \
        'echo "--- Claude Desktop Launcher Start ---" >> "$LOG_FILE"' \
        'echo "Timestamp: $(date)" >> "$LOG_FILE"' \
        'echo "Arguments: $@" >> "$LOG_FILE"' \
        '' \
        '# Detect if Wayland is likely running' \
        'IS_WAYLAND=false' \
        'if [ ! -z "$WAYLAND_DISPLAY" ]; then' \
        '  IS_WAYLAND=true' \
        '  echo "Wayland detected" >> "$LOG_FILE"' \
        'fi' \
        '' \
        '# Determine Electron executable path (always local now)' \
        'PACKAGE_NAME="claude-desktop" # Define package name for path construction' \
        'LOCAL_ELECTRON_PATH="/usr/lib/$PACKAGE_NAME/node_modules/electron/dist/electron"' \
        'ELECTRON_EXEC=""' \
        'if [ -f "$LOCAL_ELECTRON_PATH" ]; then' \
        '    ELECTRON_EXEC="$LOCAL_ELECTRON_PATH"' \
        '    echo "Using local Electron: $ELECTRON_EXEC" >> "$LOG_FILE"' \
        'else' \
        '    echo "Error: Electron executable not found at local path $LOCAL_ELECTRON_PATH." >> "$LOG_FILE"' \
        '    # Optionally, display an error to the user via zenity or kdialog if available' \
        '    if command -v zenity &> /dev/null; then' \
        '        zenity --error --text="Claude Desktop cannot start because the Electron framework is missing from the package ($LOCAL_ELECTRON_PATH). Please reinstall Claude Desktop."' \
        '    elif command -v kdialog &> /dev/null; then' \
        '        kdialog --error "Claude Desktop cannot start because the Electron framework is missing from the package ($LOCAL_ELECTRON_PATH). Please reinstall Claude Desktop."' \
        '    fi' \
        '    exit 1' \
        'fi' \
        '' \
        '# Base command arguments array, starting with app path' \
        'APP_PATH="/usr/lib/$PACKAGE_NAME/app.asar"' \
        'ELECTRON_ARGS=("$APP_PATH")' \
        '' \
        '# Add Wayland flags if Wayland is detected' \
        'if [ "$IS_WAYLAND" = true ]; then' \
        '  echo "Adding Wayland flags" >> "$LOG_FILE"' \
        '  ELECTRON_ARGS+=("--enable-features=UseOzonePlatform,WaylandWindowDecorations" "--ozone-platform=wayland")' \
        'fi' \
        '' \
        '# Change to the application directory' \
        'APP_DIR="/usr/lib/$PACKAGE_NAME"' \
        'echo "Changing directory to $APP_DIR" >> "$LOG_FILE"' \
        'cd "$APP_DIR" || { echo "Failed to cd to $APP_DIR" >> "$LOG_FILE"; exit 1; }' \
        '' \
        '# Execute Electron with app path, flags, and script arguments' \
        '# Redirect stdout and stderr to the log file' \
        'FINAL_CMD="$ELECTRON_EXEC ${ELECTRON_ARGS[@]} $@" # For logging' \
        'echo "Executing: $FINAL_CMD" >> "$LOG_FILE"' \
        '"$ELECTRON_EXEC" "${ELECTRON_ARGS[@]}" "$@" >> "$LOG_FILE" 2>&1' \
        'EXIT_CODE=$?' \
        'echo "Electron exited with code: $EXIT_CODE" >> "$LOG_FILE"' \
        'echo "--- Claude Desktop Launcher End ---" >> "$LOG_FILE"' \
        'exit $EXIT_CODE' \
        > "$launcher_path"

    chmod +x "$launcher_path"
    log_success "✓ Launcher script created."
}

create_control_file() {
    log_step "Create Control File"
    local control_file="$PACKAGE_ROOT/DEBIAN/control"
    log_info "Creating control file at $control_file..."
    # Determine dependencies
    # Electron is now always packaged locally, so it's not listed as an external dependency.
    local depends="nodejs (>= 16), npm, p7zip-full, libnotify4, libappindicator3-1, libxtst6, libnss3, libxss1, libasound2" # Common Electron runtime deps
    log_info "Dependencies: $depends"

    # Use printf for heredoc content
    printf '%s\n' \
        "Package: $PACKAGE_NAME" \
        "Version: $VERSION" \
        "Architecture: $ARCHITECTURE" \
        "Maintainer: $MAINTAINER" \
        "Depends: $depends" \
        "Description: $DESCRIPTION" \
        " Claude is an AI assistant from Anthropic." \
        " This package provides the desktop interface for Claude." \
        " ." \
        " Supported on Debian-based Linux distributions (Debian, Ubuntu, Linux Mint, etc.)" \
        > "$control_file"
    log_success "✓ Control file created."
}

create_postinst_script() {
    log_step "Create Postinst Script"
    local postinst_file="$PACKAGE_ROOT/DEBIAN/postinst"
    log_info "Creating postinst script at $postinst_file..."
    # Use printf for heredoc content
    printf '%s\n' \
        '#!/bin/sh' \
        'set -e' \
        '' \
        'PACKAGE_NAME="claude-desktop" # Define package name for path construction' \
        '' \
        '# Update desktop database for MIME types and icons' \
        'echo "Updating desktop database..."' \
        'if command -v update-desktop-database >/dev/null 2>&1; then' \
        '  update-desktop-database /usr/share/applications' \
        'else' \
        '  echo "Warning: update-desktop-database command not found. Desktop integration might be incomplete."' \
        'fi' \
        'if command -v gtk-update-icon-cache >/dev/null 2>&1; then' \
        '  gtk-update-icon-cache /usr/share/icons/hicolor || true' \
        'else' \
        '  echo "Warning: gtk-update-icon-cache command not found. Icon cache might not be updated."' \
        'fi' \
        '' \
        '# Set correct permissions for chrome-sandbox (always local now)' \
        'echo "Setting chrome-sandbox permissions..."' \
        'LOCAL_SANDBOX_PATH="/usr/lib/$PACKAGE_NAME/node_modules/electron/dist/chrome-sandbox"' \
        'if [ -f "$LOCAL_SANDBOX_PATH" ]; then' \
        '    echo "Found chrome-sandbox at: $LOCAL_SANDBOX_PATH"' \
        '    chown root:root "$LOCAL_SANDBOX_PATH" || echo "Warning: Failed to chown chrome-sandbox"' \
        '    chmod 4755 "$LOCAL_SANDBOX_PATH" || echo "Warning: Failed to chmod chrome-sandbox"' \
        '    echo "Permissions set for $LOCAL_SANDBOX_PATH"' \
        'else' \
        '    echo "Warning: chrome-sandbox binary not found in local package at $LOCAL_SANDBOX_PATH. Sandbox may not function correctly."' \
        'fi' \
        '' \
        'echo "Post-installation steps finished."' \
        'exit 0' \
        > "$postinst_file"

    chmod +x "$postinst_file"
    log_success "✓ Postinst script created."
}

build_package() {
    log_step "Build .deb Package"
    log_info "Building package..."
    if ! dpkg-deb --build "$PACKAGE_ROOT" "$DEB_FILE"; then
        fail "Failed to build .deb package using dpkg-deb"
    fi
    log_success "✓ .deb package built successfully: $DEB_FILE"
}

# --- Main Execution ---

main() {
    # Assign arguments to global variables
    VERSION="${1?Version argument missing}"
    ARCHITECTURE="${2?Architecture argument missing}"
    WORK_DIR="${3?Work directory argument missing}"
    APP_STAGING_DIR="${4?App staging directory argument missing}"
    PACKAGE_NAME="${5?Package name argument missing}"
    MAINTAINER="${6?Maintainer argument missing}"
    DESCRIPTION="${7?Description argument missing}"

    log_info "--- Starting Debian Package Build ---"
    log_info "Version: $VERSION"
    log_info "Architecture: $ARCHITECTURE"
    log_info "Work Directory: $WORK_DIR"
    log_info "App Staging Directory: $APP_STAGING_DIR"
    log_info "Package Name: $PACKAGE_NAME"

    setup_variables_and_dirs
    install_icons
    copy_app_files
    create_desktop_entry
    create_launcher_script
    create_control_file
    create_postinst_script
    build_package

    log_info "--- Debian Package Build Finished ---"
}

# Execute main function, passing all script arguments
main "$@"