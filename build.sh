#!/bin/bash
#
# build.sh - Build script for Claude Desktop Linux packages (.deb or .AppImage)
#

# --- Strict Mode & Globals ---
set -euo pipefail

# Global variables (will be populated by functions)
HOST_ARCH=""
CLAUDE_DOWNLOAD_URL=""
ARCHITECTURE=""
CLAUDE_EXE_FILENAME=""
ORIGINAL_USER=""
ORIGINAL_HOME=""
PROJECT_ROOT=""
WORK_DIR=""
APP_STAGING_DIR=""
BUILD_FORMAT="deb" # Default build format
CLEANUP_ACTION="yes" # Default cleanup action
TEST_FLAGS_MODE=false
PERFORM_CLEANUP=true
CHOSEN_ELECTRON_MODULE_PATH=""
ASAR_EXEC=""
VERSION=""
PACKAGE_NAME="claude-desktop"
MAINTAINER="Claude Desktop Linux Maintainers"
DESCRIPTION="Claude Desktop for Linux"
FINAL_OUTPUT_PATH=""
FINAL_DESKTOP_FILE_PATH=""
NVM_DIR="" # Define NVM_DIR globally

# --- Helper Functions ---

# Print messages with color and formatting
# Usage: log_info "Message", log_warn "Message", log_error "Message", log_success "Message", log_step "Step Title"
_log() {
    local color_code="$1"
    shift
    # Use $'... ' quoting to ensure \033 is interpreted by bash before printf
    printf $'\033[%sm%b\033[0m\n' "$color_code" "$*"
}
log_info()    { _log "0"    "INFO: $*"; }
log_warn()    { _log "1;33" "WARN: $*"; }
log_error()   { _log "1;31" "ERROR: $*"; } >&2 # Errors to stderr
log_success() { _log "1;32" "SUCCESS: $*"; }
log_step()    { _log "1;36" "\n--- $1 ---"; }

# Check if a command exists
check_command() {
    local cmd="$1"
    if command -v "$cmd" &> /dev/null; then
        log_success "✓ $cmd found"
        return 0
    else
        log_error "❌ $cmd not found"
        return 1
    fi
}

# Exit script with an error message
fail() {
    log_error "$@"
    exit 1
}

# --- Core Logic Functions ---

detect_architecture() {
    log_step "Architecture Detection"
    log_info "⚙️ Detecting system architecture..."
    HOST_ARCH=$(dpkg --print-architecture)
    log_info "Detected host architecture: $HOST_ARCH"
    # Optional: More detailed info
    # cat /etc/os-release && uname -m && dpkg --print-architecture

    case "$HOST_ARCH" in
        "amd64")
            CLAUDE_DOWNLOAD_URL="https://storage.googleapis.com/osprey-downloads-c02f6a0d-347c-492b-a752-3e0651722e97/nest-win-x64/Claude-Setup-x64.exe"
            ARCHITECTURE="amd64"
            CLAUDE_EXE_FILENAME="Claude-Setup-x64.exe"
            log_info "Configured for amd64 build."
            ;;
        "arm64")
            CLAUDE_DOWNLOAD_URL="https://storage.googleapis.com/osprey-downloads-c02f6a0d-347c-492b-a752-3e0651722e97/nest-win-arm64/Claude-Setup-arm64.exe"
            ARCHITECTURE="arm64"
            CLAUDE_EXE_FILENAME="Claude-Setup-arm64.exe"
            log_info "Configured for arm64 build."
            ;;
        *)
            fail "Unsupported architecture: $HOST_ARCH. This script currently supports amd64 and arm64."
            ;;
    esac
    log_info "Target Architecture (detected): $ARCHITECTURE"
}

preliminary_checks() {
    log_step "Preliminary Checks"
    if [ ! -f "/etc/debian_version" ]; then
        fail "This script requires a Debian-based Linux distribution."
    fi

    if [ "$EUID" -eq 0 ]; then
       log_error "This script should not be run using sudo or as the root user."
       log_error "It will prompt for sudo password when needed for specific actions."
       log_error "Please run as a normal user."
       exit 1
    fi

    ORIGINAL_USER=$(whoami)
    ORIGINAL_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)
    if [ -z "$ORIGINAL_HOME" ]; then
        fail "Could not determine home directory for user $ORIGINAL_USER."
    fi
    log_info "Running as user: $ORIGINAL_USER (Home: $ORIGINAL_HOME)"
}

setup_nvm() {
    log_step "NVM Setup (if applicable)"
    # Check for NVM and source it if found to ensure npm/npx are available later
    NVM_DIR="$ORIGINAL_HOME/.nvm" # Use global NVM_DIR
    if [ -d "$NVM_DIR" ]; then
        log_info "Found NVM installation for user $ORIGINAL_USER, attempting to activate..."
        export NVM_DIR # Export NVM_DIR for the nvm script
        if [ -s "$NVM_DIR/nvm.sh" ]; then
            # Source NVM script to set up NVM environment variables temporarily
            # shellcheck disable=SC1091
            \. "$NVM_DIR/nvm.sh" # This loads nvm
            # Initialize and find the path to the currently active or default Node version's bin directory
            local node_bin_path=""
            # Try 'nvm which' first, fall back to find if needed
            node_bin_path=$(nvm which current 2>/dev/null | xargs dirname || find "$NVM_DIR/versions/node" -maxdepth 2 -type d -name 'bin' | sort -V | tail -n 1)

            if [ -n "$node_bin_path" ] && [ -d "$node_bin_path" ]; then
                log_info "Adding NVM Node bin path to PATH: $node_bin_path"
                export PATH="$node_bin_path:$PATH"
            else
                log_warn "Could not determine NVM Node bin path. npm/npx might not be found."
            fi
        else
            log_warn "nvm.sh script not found or not sourceable in $NVM_DIR."
        fi
    else
        log_info "NVM directory not found at $NVM_DIR. Assuming node/npm are in standard PATH."
    fi
}


print_system_info_and_vars() {
    log_step "System Information & Build Variables"
    log_info "Distribution: $(grep "PRETTY_NAME" /etc/os-release | cut -d'"' -f2)"
    log_info "Debian version: $(cat /etc/debian_version)"
    log_info "Target Architecture: $ARCHITECTURE"

    PROJECT_ROOT="$(pwd)"
    WORK_DIR="$PROJECT_ROOT/build"
    APP_STAGING_DIR="$WORK_DIR/electron-app"

    log_info "Project Root: $PROJECT_ROOT"
    log_info "Work Directory: $WORK_DIR"
    log_info "App Staging Directory: $APP_STAGING_DIR"
    log_info "Package Name: $PACKAGE_NAME"
    log_info "Maintainer: $MAINTAINER"
    log_info "Description: $DESCRIPTION"
}

parse_arguments() {
    log_step "Argument Parsing"
    while [[ $# -gt 0 ]]; do
        local key="$1"
        case "$key" in
            -b|--build)
                if [[ -z "${2:-}" || "${2:0:1}" == "-" ]]; then fail "Argument for $1 is missing"; fi
                BUILD_FORMAT="$2"
                shift 2 ;;
            -c|--clean)
                if [[ -z "${2:-}" || "${2:0:1}" == "-" ]]; then fail "Argument for $1 is missing"; fi
                CLEANUP_ACTION="$2"
                shift 2 ;;
            --test-flags)
                TEST_FLAGS_MODE=true
                shift ;;
            -h|--help)
                printf "Usage: %s [--build deb|appimage] [--clean yes|no] [--test-flags]\n" "$0"
                printf "  --build: Specify the build format (deb or appimage). Default: deb\n"
                printf "  --clean: Specify whether to clean intermediate build files (yes or no). Default: yes\n"
                printf "  --test-flags: Parse flags, print results, and exit without building.\n"
                exit 0 ;;
            *)
                fail "Unknown option: $1. Use -h or --help for usage information." ;;
        esac
    done

    # Validate and normalize arguments
    BUILD_FORMAT=$(echo "$BUILD_FORMAT" | tr '[:upper:]' '[:lower:]')
    CLEANUP_ACTION=$(echo "$CLEANUP_ACTION" | tr '[:upper:]' '[:lower:]')

    if [[ "$BUILD_FORMAT" != "deb" && "$BUILD_FORMAT" != "appimage" ]]; then
        fail "Invalid build format specified: '$BUILD_FORMAT'. Must be 'deb' or 'appimage'."
    fi
    if [[ "$CLEANUP_ACTION" != "yes" && "$CLEANUP_ACTION" != "no" ]]; then
        fail "Invalid cleanup option specified: '$CLEANUP_ACTION'. Must be 'yes' or 'no'."
    fi

    log_info "Selected build format: $BUILD_FORMAT"
    log_info "Cleanup intermediate files: $CLEANUP_ACTION"

    PERFORM_CLEANUP=false
    if [ "$CLEANUP_ACTION" = "yes" ]; then
        PERFORM_CLEANUP=true
    fi

    # Exit early if --test-flags mode is enabled
    if [ "$TEST_FLAGS_MODE" = true ]; then
        log_step "Test Flags Mode Enabled"
        log_info "Build Format: $BUILD_FORMAT"
        log_info "Clean Action: $CLEANUP_ACTION"
        log_info "Exiting without build."
        exit 0
    fi
}

check_dependencies() {
    log_step "Dependency Check & Installation"
    local deps_to_install=""
    local common_deps="p7zip wget wrestool icotool convert npx"
    local deb_deps="dpkg-dev" # dpkg-deb is part of dpkg, dpkg-dev is needed for building
    local appimage_deps="" # Add AppImage specific deps here if any
    local all_deps_to_check="$common_deps"

    if [ "$BUILD_FORMAT" = "deb" ]; then
        all_deps_to_check="$all_deps_to_check $deb_deps"
    elif [ "$BUILD_FORMAT" = "appimage" ]; then
        all_deps_to_check="$all_deps_to_check $appimage_deps"
    fi

    log_info "Checking for: $all_deps_to_check"
    for cmd in $all_deps_to_check; do
        if ! check_command "$cmd"; then
            case "$cmd" in
                "p7zip") deps_to_install="$deps_to_install p7zip-full" ;;
                "wget") deps_to_install="$deps_to_install wget" ;;
                "wrestool"|"icotool") deps_to_install="$deps_to_install icoutils" ;;
                "convert") deps_to_install="$deps_to_install imagemagick" ;;
                "npx") deps_to_install="$deps_to_install nodejs npm" ;; # Suggest nodejs/npm if npx missing
                "dpkg-dev") deps_to_install="$deps_to_install dpkg-dev" ;;
                # Add cases for AppImage deps if needed
            esac
        fi
    done

    # Remove duplicates
    deps_to_install=$(echo "$deps_to_install" | xargs -n1 | sort -u | xargs)

    if [ -n "$deps_to_install" ]; then
        log_warn "System dependencies needed: $deps_to_install"
        log_info "Attempting to install using sudo..."
        if ! sudo -v; then
            fail "Failed to validate sudo credentials. Please ensure you can run sudo."
        fi
        if ! sudo apt-get update -qq; then
            fail "Failed to run 'sudo apt-get update'."
        fi
        # shellcheck disable=SC2086 # We want word splitting here
        if ! sudo apt-get install -y $deps_to_install; then
             fail "Failed to install dependencies using 'sudo apt-get install'."
        fi
        log_success "✓ System dependencies installed successfully via sudo."
    else
        log_success "✓ All required dependencies are present."
    fi
}

prepare_build_dir() {
    log_step "Prepare Build Directory"
    log_info "Cleaning up and creating work directories..."
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    mkdir -p "$APP_STAGING_DIR"
    log_success "✓ Build directories prepared."
}

setup_electron_asar() {
    log_step "Electron & Asar Setup"
    log_info "Ensuring local Electron and Asar installation in $WORK_DIR..."
    local install_needed=false
    local electron_dist_path="$WORK_DIR/node_modules/electron/dist"
    local asar_bin_path="$WORK_DIR/node_modules/.bin/asar"

    # Temporarily change to WORK_DIR for npm install
    pushd "$WORK_DIR" > /dev/null

    # Always ensure Electron and Asar are installed in the clean WORK_DIR
    log_info "Ensuring Electron and Asar are installed locally into $WORK_DIR..."
    if [ ! -f "package.json" ]; then
        log_info "Creating temporary package.json..."
        echo '{"name":"claude-desktop-build","version":"0.0.1","private":true,"description":"Temporary package for build dependencies"}' > package.json
    fi
        # Use npm ci for potentially faster/more reliable installs if package-lock.json existed
        if ! npm install --no-save --loglevel error electron @electron/asar; then
            popd > /dev/null # Return to original directory before failing
            fail "Failed to install Electron and/or Asar locally."
        fi
        log_success "✓ Electron and Asar installation command finished."

    # Verify paths after potential install
    if [ -d "$electron_dist_path" ]; then
        log_success "✓ Found Electron distribution directory at $electron_dist_path."
        # Get absolute path
        CHOSEN_ELECTRON_MODULE_PATH="$(realpath "$WORK_DIR/node_modules/electron")"
        log_info "✓ Setting Electron module path for copying to $CHOSEN_ELECTRON_MODULE_PATH."
    else
        popd > /dev/null
        fail "Failed to find Electron distribution directory at '$electron_dist_path' after installation attempt."
    fi

    if [ -x "$asar_bin_path" ]; then
        ASAR_EXEC="$(realpath "$asar_bin_path")"
        log_success "✓ Found local Asar binary at $ASAR_EXEC."
    else
        popd > /dev/null
        fail "Failed to find Asar binary at '$asar_bin_path' after installation attempt."
    fi

    popd > /dev/null # Return to original directory

    log_info "Using Electron module path: $CHOSEN_ELECTRON_MODULE_PATH"
    log_info "Using asar executable: $ASAR_EXEC"
}

download_and_extract_claude() {
    log_step "Download & Extract Claude"
    log_info "📥 Downloading Claude Desktop installer for $ARCHITECTURE..."
    local claude_exe_path="$WORK_DIR/$CLAUDE_EXE_FILENAME"
    if ! wget --quiet --show-progress -O "$claude_exe_path" "$CLAUDE_DOWNLOAD_URL"; then
        fail "Failed to download Claude Desktop installer from $CLAUDE_DOWNLOAD_URL"
    fi
    log_success "✓ Download complete: $CLAUDE_EXE_FILENAME"

    log_info "📦 Extracting resources from $CLAUDE_EXE_FILENAME..."
    local claude_extract_dir="$WORK_DIR/claude-extract"
    mkdir -p "$claude_extract_dir"
    # Use 7z with -bso0 to minimize output, check exit code
    if ! 7z x -y "$claude_exe_path" -o"$claude_extract_dir" -bso0; then
        fail "Failed to extract installer using 7z"
    fi
    log_success "✓ Installer extracted to $claude_extract_dir"

    pushd "$claude_extract_dir" > /dev/null # Change into the extract dir

    local nupkg_path_relative
    nupkg_path_relative=$(find . -maxdepth 1 -name "AnthropicClaude-*.nupkg" -print -quit) # More efficient find
    if [ -z "$nupkg_path_relative" ]; then
        popd > /dev/null
        fail "Could not find AnthropicClaude nupkg file in $claude_extract_dir"
    fi
    local nupkg_path="$claude_extract_dir/$nupkg_path_relative"
    log_info "Found nupkg: $nupkg_path_relative (in $claude_extract_dir)"

    # Extract version using parameter expansion for robustness
    local base_nupkg="${nupkg_path_relative##*/}" # Get filename
    base_nupkg="${base_nupkg#AnthropicClaude-}" # Remove prefix
    VERSION="${base_nupkg%%-*}" # Extract version part

    if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        popd > /dev/null
        fail "Could not extract valid version (x.y.z) from nupkg filename: $nupkg_path_relative"
    fi
    log_success "✓ Detected Claude version: $VERSION"
    export VERSION # Export the version so sub-scripts can see it

    log_info "Extracting nupkg..."
    if ! 7z x -y "$nupkg_path_relative" -bso0; then
        popd > /dev/null
        fail "Failed to extract nupkg"
    fi
    log_success "✓ Resources extracted from nupkg"

    local exe_relative_path="lib/net45/claude.exe"
    if [ ! -f "$exe_relative_path" ]; then
        popd > /dev/null
        fail "Cannot find claude.exe at expected path: $claude_extract_dir/$exe_relative_path"
    fi

    log_info "🎨 Processing icons from $exe_relative_path..."
    if ! wrestool -x -t 14 "$exe_relative_path" -o claude.ico; then
        popd > /dev/null
        fail "Failed to extract icons from exe using wrestool"
    fi
    if ! icotool -x claude.ico; then
        popd > /dev/null
        fail "Failed to convert icons using icotool"
    fi
    # Copy only PNGs, handle potential errors
    find . -maxdepth 1 -name 'claude_*.png' -exec cp {} "$WORK_DIR/" \; || log_warn "Could not copy all PNG icons."
    log_success "✓ Icons processed and copied to $WORK_DIR"

    popd > /dev/null # Return to original directory
}

process_asar() {
    log_step "Process app.asar"
    local claude_extract_dir="$WORK_DIR/claude-extract" # Re-define locally for clarity
    local resources_path="$claude_extract_dir/lib/net45/resources"

    log_info "Copying asar and unpacked resources to staging..."
    cp "$resources_path/app.asar" "$APP_STAGING_DIR/"
    # Ensure unpacked dir exists before copying
    if [ -d "$resources_path/app.asar.unpacked" ]; then
        cp -a "$resources_path/app.asar.unpacked" "$APP_STAGING_DIR/"
    else
        log_warn "app.asar.unpacked directory not found in extracted resources. Skipping copy."
        mkdir -p "$APP_STAGING_DIR/app.asar.unpacked" # Create empty if missing
    fi


    pushd "$APP_STAGING_DIR" > /dev/null # Enter staging dir

    log_info "Extracting app.asar contents..."
    "$ASAR_EXEC" extract app.asar app.asar.contents

    log_info "Creating stub native module..."
    local native_stub_dir="app.asar.contents/node_modules/claude-native"
    local native_stub_path="$native_stub_dir/index.js"
    mkdir -p "$native_stub_dir"
    # Use printf for the heredoc content for consistency
    printf '%s\n' \
        "// Stub implementation of claude-native using KeyboardKey enum values" \
        "const KeyboardKey = { Backspace: 43, Tab: 280, Enter: 261, Shift: 272, Control: 61, Alt: 40, CapsLock: 56, Escape: 85, Space: 276, PageUp: 251, PageDown: 250, End: 83, Home: 154, LeftArrow: 175, UpArrow: 282, RightArrow: 262, DownArrow: 81, Delete: 79, Meta: 187 };" \
        "Object.freeze(KeyboardKey);" \
        "module.exports = { getWindowsVersion: () => \"10.0.0\", setWindowEffect: () => {}, removeWindowEffect: () => {}, getIsMaximized: () => false, flashFrame: () => {}, clearFlashFrame: () => {}, showNotification: () => {}, setProgressBar: () => {}, clearProgressBar: () => {}, setOverlayIcon: () => {}, clearOverlayIcon: () => {}, KeyboardKey };" \
        > "$native_stub_path"

    log_info "Copying additional resources (Tray icons, i18n)..."
    local content_resources_dir="app.asar.contents/resources"
    local content_i18n_dir="$content_resources_dir/i18n"
    mkdir -p "$content_resources_dir"
    mkdir -p "$content_i18n_dir"
    # Use find to copy safely, handle missing files gracefully
    find "$resources_path" -maxdepth 1 -name 'Tray*' -exec cp {} "$content_resources_dir/" \; || log_warn "Could not copy all Tray icons."
    find "$resources_path" -maxdepth 1 -name '*-*.json' -exec cp {} "$content_i18n_dir/" \; || log_warn "Could not copy all i18n JSON files."

    log_info "Patching MainWindowPage JS for title bar..."
    local search_base="app.asar.contents/.vite/renderer/main_window/assets"
    local target_pattern="MainWindowPage-*.js"
    local target_file
    target_file=$(find "$search_base" -type f -name "$target_pattern" -print -quit)

    if [ -z "$target_file" ]; then
        popd > /dev/null
        fail "No file matching '$target_pattern' found within '$search_base'."
    fi
    # Check for multiple files (though -quit should prevent this)
    local num_files
    num_files=$(find "$search_base" -type f -name "$target_pattern" | wc -l)
     if [ "$num_files" -gt 1 ]; then
        popd > /dev/null
        fail "Expected exactly one file matching '$target_pattern', but found $num_files."
    fi

    log_info "Found target file: $target_file"
    log_info "Attempting to replace '!d&&e' with 'd&&e'..."
    # Use sed with a backup for safety, then check
    sed -i.bak 's/!d&&e/d\&\&e/g' "$target_file"
    if grep -q 'd\&\&e' "$target_file" && ! grep -q '!d\&\&e' "$target_file"; then
        log_success "Successfully patched $target_file."
        rm "${target_file}.bak" # Remove backup on success
    else
        log_error "Failed to replace '!d&&e' in $target_file. Check file contents and backup."
        # Keep the backup file (.bak) for inspection
        popd > /dev/null
        fail "Patching failed."
    fi

    log_info "Repacking app.asar..."
    "$ASAR_EXEC" pack app.asar.contents app.asar

    log_info "Creating stub native module in app.asar.unpacked..."
    local unpacked_native_stub_dir="$APP_STAGING_DIR/app.asar.unpacked/node_modules/claude-native"
    mkdir -p "$unpacked_native_stub_dir"
    cp "$native_stub_path" "$unpacked_native_stub_dir/index.js" # Copy the already created stub

    log_info "Copying Electron installation to staging area..."
    local electron_dir_name
    electron_dir_name=$(basename "$CHOSEN_ELECTRON_MODULE_PATH")
    local staged_electron_path="$APP_STAGING_DIR/node_modules/$electron_dir_name"
    mkdir -p "$APP_STAGING_DIR/node_modules/"
    log_info "Copying from $CHOSEN_ELECTRON_MODULE_PATH to $APP_STAGING_DIR/node_modules/"
    cp -a "$CHOSEN_ELECTRON_MODULE_PATH" "$APP_STAGING_DIR/node_modules/"

    local staged_electron_bin="$staged_electron_path/dist/electron"
    if [ -f "$staged_electron_bin" ]; then
        log_info "Setting executable permission on staged Electron binary..."
        chmod +x "$staged_electron_bin"
    else
        log_warn "Staged Electron binary not found at expected path: $staged_electron_bin"
    fi

    popd > /dev/null # Return to original directory
    log_success "✓ app.asar processed and staged in $APP_STAGING_DIR"
}

package_application() {
    log_step "Call Packaging Script"
    cd "$PROJECT_ROOT" # Ensure we are in the project root

    if [ "$BUILD_FORMAT" = "deb" ]; then
        log_info "📦 Calling Debian packaging script for $ARCHITECTURE..."
        local script_path="scripts/build-deb-package.sh"
        chmod +x "$script_path"
        if ! "$script_path" \
            "$VERSION" "$ARCHITECTURE" "$WORK_DIR" "$APP_STAGING_DIR" \
            "$PACKAGE_NAME" "$MAINTAINER" "$DESCRIPTION"; then
            fail "Debian packaging script failed."
        fi
        local deb_file
        deb_file=$(find "$WORK_DIR" -maxdepth 1 -name "${PACKAGE_NAME}_${VERSION}_${ARCHITECTURE}.deb" -print -quit)
        log_success "✓ Debian Build complete!"
        if [ -n "$deb_file" ] && [ -f "$deb_file" ]; then
            FINAL_OUTPUT_PATH="./$(basename "$deb_file")"
            mv "$deb_file" "$FINAL_OUTPUT_PATH"
            log_success "Package created at: $FINAL_OUTPUT_PATH"
        else
            log_warn "Could not determine final .deb file path from $WORK_DIR."
            FINAL_OUTPUT_PATH="Not Found"
        fi

    elif [ "$BUILD_FORMAT" = "appimage" ]; then
        log_info "📦 Calling AppImage packaging script for $ARCHITECTURE..."
        local script_path="scripts/build-appimage.sh"
        chmod +x "$script_path"
        if ! "$script_path" \
            "$VERSION" "$ARCHITECTURE" "$WORK_DIR" "$APP_STAGING_DIR" "$PACKAGE_NAME"; then
            fail "AppImage packaging script failed."
        fi
        local appimage_file
        appimage_file=$(find "$WORK_DIR" -maxdepth 1 -name "${PACKAGE_NAME}-${VERSION}-${ARCHITECTURE}.AppImage" -print -quit)
        log_success "✓ AppImage Build complete!"
        if [ -n "$appimage_file" ] && [ -f "$appimage_file" ]; then
            FINAL_OUTPUT_PATH="./$(basename "$appimage_file")"
            mv "$appimage_file" "$FINAL_OUTPUT_PATH"
            log_success "Package created at: $FINAL_OUTPUT_PATH"
        else
            log_warn "Could not determine final .AppImage file path from $WORK_DIR."
            FINAL_OUTPUT_PATH="Not Found"
        fi
    fi
}

cleanup() {
    log_step "Cleanup"
    if [ "$PERFORM_CLEANUP" = true ]; then
        log_info "🧹 Cleaning up intermediate build files in $WORK_DIR..."
        if rm -rf "$WORK_DIR"; then
            log_success "✓ Cleanup complete ($WORK_DIR removed)."
        else
            log_warn "Cleanup command (rm -rf $WORK_DIR) failed."
        fi
    else
        log_info "Skipping cleanup of intermediate build files in $WORK_DIR."
    fi
}

print_next_steps() {
    log_step "Build Process Finished"
    printf "\n\033[1;34m====== Next Steps ======\033[0m\n"
    if [ "$BUILD_FORMAT" = "deb" ]; then
        if [ "$FINAL_OUTPUT_PATH" != "Not Found" ] && [ -e "$FINAL_OUTPUT_PATH" ]; then
            printf "📦 To install the Debian package, run:\n"
            printf "   \033[1;32msudo apt install %s\033[0m\n" "$FINAL_OUTPUT_PATH"
            printf "   (or \`sudo dpkg -i %s\`)\n" "$FINAL_OUTPUT_PATH"
        else
            log_warn "Debian package file not found. Cannot provide installation instructions."
        fi
    elif [ "$BUILD_FORMAT" = "appimage" ]; then
        if [ "$FINAL_OUTPUT_PATH" != "Not Found" ] && [ -e "$FINAL_OUTPUT_PATH" ]; then
            printf "✅ AppImage created at: \033[1;36m%s\033[0m\n" "$FINAL_OUTPUT_PATH"
            if [ -e "$FINAL_DESKTOP_FILE_PATH" ]; then
                 printf "   Associated .desktop file: \033[1;36m%s\033[0m\n" "$FINAL_DESKTOP_FILE_PATH"
            fi
            printf "\n\033[1;33mIMPORTANT:\033[0m This AppImage requires \033[1;36mAppImageLauncher\033[0m for proper desktop integration\n"
            printf "and to handle the \`claude://\` login process correctly.\n"
            printf "\n🚀 To install AppImageLauncher (example for v2.2.0 amd64):\n"
            printf "   1. Download:\n"
            printf "      \033[1;32mwget https://github.com/TheAssassin/AppImageLauncher/releases/download/v2.2.0/appimagelauncher_2.2.0-travis995.0f91801.bionic_amd64.deb -O /tmp/appimagelauncher.deb\033[0m\n"
            printf "       - or find the appropriate package here: \033[1;34mhttps://github.com/TheAssassin/AppImageLauncher/releases/latest\033[0m\n"
            printf "   2. Install the package:\n"
            printf "      \033[1;32msudo apt install /tmp/appimagelauncher.deb\033[0m\n"
            printf "   3. Make the AppImage executable:\n"
            printf "      \033[1;32mchmod +x %s\033[0m\n" "$FINAL_OUTPUT_PATH"
            printf "   4. Run the AppImage (AppImageLauncher should prompt for integration):\n"
            printf "      \033[1;32m%s\033[0m\n" "$FINAL_OUTPUT_PATH"
            printf "   5. (Optional) If integration doesn't happen automatically, move the .desktop file:\n"
            printf "      \033[1;32mmkdir -p ~/.local/share/applications\033[0m\n"
            printf "      \033[1;32mcp %s ~/.local/share/applications/\033[0m\n" "$FINAL_DESKTOP_FILE_PATH"
            printf "      \033[1;32mupdate-desktop-database ~/.local/share/applications\033[0m\n"
        else
            log_warn "AppImage file not found. Cannot provide usage instructions."
        fi
    fi
    printf "\n" # Final newline for cleaner terminal output
}


# --- Main Execution ---

main() {
    # Pass all script arguments to parse_arguments
    parse_arguments "$@"

    detect_architecture
    preliminary_checks
    setup_nvm # Attempt to set up NVM if present
    print_system_info_and_vars
    check_dependencies
    prepare_build_dir
    setup_electron_asar
    download_and_extract_claude
    process_asar
    package_application
    cleanup
    print_next_steps
}

# Execute main function, passing all script arguments
main "$@"