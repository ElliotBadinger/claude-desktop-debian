#!/bin/bash
set -euo pipefail

echo -e "\033[1;36m--- Build Part 1: Setup and Preparation (in build_dev) ---\033[0m"

PROJECT_ROOT="$(pwd)"
BUILD_DEV_DIR="$PROJECT_ROOT/build_dev" # Define build_dev path

# --- Clean and Create build_dev Directory ---
echo "Cleaning and creating development build directory: $BUILD_DEV_DIR"
rm -rf "$BUILD_DEV_DIR"
mkdir -p "$BUILD_DEV_DIR"
echo "✓ Development build directory prepared."

# --- Define Paths within build_dev ---
WORK_DIR="$BUILD_DEV_DIR" # All work happens directly in build_dev
APP_STAGING_DIR="$WORK_DIR/electron-app" # Staging area within build_dev
echo "Using WORK_DIR: $WORK_DIR"
echo "Using APP_STAGING_DIR: $APP_STAGING_DIR"

# --- Architecture Detection ---
echo "⚙️ Detecting system architecture..."
HOST_ARCH=$(dpkg --print-architecture)
echo "Detected host architecture: $HOST_ARCH"
if [ "$HOST_ARCH" = "amd64" ]; then
    CLAUDE_DOWNLOAD_URL="https://storage.googleapis.com/osprey-downloads-c02f6a0d-347c-492b-a752-3e0651722e97/nest-win-x64/Claude-Setup-x64.exe"
    ARCHITECTURE="amd64"
    CLAUDE_EXE_FILENAME="Claude-Setup-x64.exe"
    echo "Configured for amd64 build."
elif [ "$HOST_ARCH" = "arm64" ]; then
    CLAUDE_DOWNLOAD_URL="https://storage.googleapis.com/osprey-downloads-c02f6a0d-347c-492b-a752-3e0651722e97/nest-win-arm64/Claude-Setup-arm64.exe"
    ARCHITECTURE="arm64"
    CLAUDE_EXE_FILENAME="Claude-Setup-arm64.exe"
    echo "Configured for arm64 build."
else
    echo "❌ Unsupported architecture: $HOST_ARCH. This script currently supports amd64 and arm64."
    exit 1
fi
echo "Target Architecture (detected): $ARCHITECTURE"
echo -e "\033[1;36m--- End Architecture Detection ---\033[0m"


# --- Environment Checks ---
if [ ! -f "/etc/debian_version" ]; then
    echo "❌ This script requires a Debian-based Linux distribution"
    exit 1
fi

if [ "$EUID" -eq 0 ]; then
   echo "❌ This script should not be run using sudo or as the root user."
   exit 1
fi

ORIGINAL_USER=$(whoami)
ORIGINAL_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)
if [ -z "$ORIGINAL_HOME" ]; then
    echo "❌ Could not determine home directory for user $ORIGINAL_USER."
    exit 1
fi
echo "Running as user: $ORIGINAL_USER (Home: $ORIGINAL_HOME)"

# --- NVM Sourcing ---
if [ -d "$ORIGINAL_HOME/.nvm" ]; then
    echo "Found NVM installation for user $ORIGINAL_USER, attempting to activate..."
    export NVM_DIR="$ORIGINAL_HOME/.nvm"
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        # shellcheck disable=SC1091
        \. "$NVM_DIR/nvm.sh" # This loads nvm
        NODE_BIN_PATH=""
        NODE_BIN_PATH=$(nvm which current | xargs dirname 2>/dev/null || find "$NVM_DIR/versions/node" -maxdepth 2 -type d -name 'bin' | sort -V | tail -n 1)

        if [ -n "$NODE_BIN_PATH" ] && [ -d "$NODE_BIN_PATH" ]; then
            echo "Adding NVM Node bin path to PATH: $NODE_BIN_PATH"
            export PATH="$NODE_BIN_PATH:$PATH"
        else
            echo "Warning: Could not determine NVM Node bin path. npm/npx might not be found."
        fi
    else
        echo "Warning: nvm.sh script not found or not sourceable."
    fi
fi


# --- Basic Variables & System Info ---
echo "System Information:"
echo "Distribution: $(grep "PRETTY_NAME" /etc/os-release | cut -d'"' -f2)"
echo "Debian version: $(cat /etc/debian_version)"
echo "Target Architecture: $ARCHITECTURE"
PACKAGE_NAME="claude-desktop"
MAINTAINER="Claude Desktop Linux Maintainers"
DESCRIPTION="Claude Desktop for Linux"
VERSION="" # Version will be detected later
echo "Project Root: $PROJECT_ROOT"


# --- Argument Parsing ---
echo -e "\033[1;36m--- Argument Parsing ---\033[0m"
BUILD_FORMAT="deb"    CLEANUP_ACTION="yes"  TEST_FLAGS_MODE=false
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -b|--build)
        if [[ -z "$2" || "$2" == -* ]]; then echo "❌ Error: Argument for $1 is missing" >&2; exit 1; fi
        BUILD_FORMAT="$2"
        shift 2 ;; # Shift past flag and value
        -c|--clean)
        # Clean argument is less relevant here as build_dev is always cleaned, but parse for consistency
        if [[ -z "$2" || "$2" == -* ]]; then echo "❌ Error: Argument for $1 is missing" >&2; exit 1; fi
        CLEANUP_ACTION="$2" # Will be passed to part 2 via vars file
        shift 2 ;; # Shift past flag and value
        --test-flags)
        TEST_FLAGS_MODE=true
        shift # past argument
        ;;
        -h|--help)
        echo "Usage: $0 [--build deb|appimage] [--clean yes|no] [--test-flags]"
        echo "  --build: Specify the build format (deb or appimage). Default: deb"
        echo "  --clean: Specify whether to clean final build files in part 2 (yes or no). Default: yes"
        echo "  --test-flags: Parse flags, print results, and exit without building."
        exit 0
        ;;
        *) echo "❌ Unknown option: $1" >&2; echo "Use -h or --help for usage information." >&2; exit 1 ;;
    esac
done

# Validate arguments
BUILD_FORMAT=$(echo "$BUILD_FORMAT" | tr '[:upper:]' '[:lower:]') CLEANUP_ACTION=$(echo "$CLEANUP_ACTION" | tr '[:upper:]' '[:lower:]')
if [[ "$BUILD_FORMAT" != "deb" && "$BUILD_FORMAT" != "appimage" ]]; then
    echo "❌ Invalid build format specified: '$BUILD_FORMAT'. Must be 'deb' or 'appimage'." >&2
    exit 1
fi
if [[ "$CLEANUP_ACTION" != "yes" && "$CLEANUP_ACTION" != "no" ]]; then
    echo "❌ Invalid cleanup option specified: '$CLEANUP_ACTION'. Must be 'yes' or 'no'." >&2
    exit 1
fi

echo "Selected build format: $BUILD_FORMAT"
echo "Cleanup intermediate files (in Part 2): $CLEANUP_ACTION"

PERFORM_CLEANUP=false
if [ "$CLEANUP_ACTION" = "yes" ]; then
    PERFORM_CLEANUP=true
fi
echo -e "\033[1;36m--- End Argument Parsing ---\033[0m"

# Exit early if --test-flags mode is enabled
if [ "$TEST_FLAGS_MODE" = true ]; then
    echo "--- Test Flags Mode Enabled ---"
    echo "Build Format: $BUILD_FORMAT"
    echo "Clean Action: $CLEANUP_ACTION"
    echo "Exiting without build."
    exit 0
fi


# --- Dependency Checks ---
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo "❌ $1 not found"
        return 1
    else
        echo "✓ $1 found"
        return 0
    fi
}

echo "Checking dependencies..."
DEPS_TO_INSTALL=""
COMMON_DEPS="p7zip wget wrestool icotool convert npx"
DEB_DEPS="dpkg-dev"
APPIMAGE_DEPS="" # Add appimagetool if needed later
ALL_DEPS_TO_CHECK="$COMMON_DEPS"
if [ "$BUILD_FORMAT" = "deb" ]; then
    ALL_DEPS_TO_CHECK="$ALL_DEPS_TO_CHECK $DEB_DEPS"
elif [ "$BUILD_FORMAT" = "appimage" ]; then
    ALL_DEPS_TO_CHECK="$ALL_DEPS_TO_CHECK $APPIMAGE_DEPS"
fi

for cmd in $ALL_DEPS_TO_CHECK; do
    if ! check_command "$cmd"; then
        case "$cmd" in
            "p7zip") DEPS_TO_INSTALL="$DEPS_TO_INSTALL p7zip-full" ;;
            "wget") DEPS_TO_INSTALL="$DEPS_TO_INSTALL wget" ;;
            "wrestool"|"icotool") DEPS_TO_INSTALL="$DEPS_TO_INSTALL icoutils" ;;
            "convert") DEPS_TO_INSTALL="$DEPS_TO_INSTALL imagemagick" ;;
            "npx") DEPS_TO_INSTALL="$DEPS_TO_INSTALL nodejs npm" ;;
            "dpkg-deb") DEPS_TO_INSTALL="$DEPS_TO_INSTALL dpkg-dev" ;;
        esac
    fi
done

if [ -n "$DEPS_TO_INSTALL" ]; then
    echo "System dependencies needed: $DEPS_TO_INSTALL"
    echo "Attempting to install using sudo..."
    if ! sudo -v; then
        echo "❌ Failed to validate sudo credentials. Please ensure you can run sudo."
        exit 1
    fi
    if ! sudo apt update; then
        echo "❌ Failed to run 'sudo apt update'."
        exit 1
    fi
    # shellcheck disable=SC2086
    if ! sudo apt install -y $DEPS_TO_INSTALL; then
         echo "❌ Failed to install dependencies using 'sudo apt install'."
         exit 1
    fi
    echo "✓ System dependencies installed successfully via sudo."
fi


# --- Create Subdirectories ---
mkdir -p "$APP_STAGING_DIR"
echo "✓ Subdirectories created within $WORK_DIR."

# --- Electron & Asar Handling ---
echo -e "\033[1;36m--- Electron & Asar Handling (in $WORK_DIR) ---\033[0m"
CHOSEN_ELECTRON_MODULE_PATH="" ASAR_EXEC=""

echo "Ensuring local Electron and Asar installation in $WORK_DIR..."
cd "$WORK_DIR" # Change to WORK_DIR (build_dev) for npm install
if [ ! -f "package.json" ]; then
    echo "Creating temporary package.json in $WORK_DIR for local install..."
    echo '{"name":"claude-desktop-build-dev","version":"0.0.1","private":true}' > package.json
fi

ELECTRON_DIST_PATH="$WORK_DIR/node_modules/electron/dist"
ASAR_BIN_PATH="$WORK_DIR/node_modules/.bin/asar"

INSTALL_NEEDED=false
if [ ! -d "$ELECTRON_DIST_PATH" ]; then
    echo "Electron distribution not found."
    INSTALL_NEEDED=true
fi
if [ ! -f "$ASAR_BIN_PATH" ]; then
    echo "Asar binary not found."
    INSTALL_NEEDED=true
fi

if [ "$INSTALL_NEEDED" = true ]; then
    echo "Installing Electron and Asar locally into $WORK_DIR..."
    if ! npm install --no-save electron @electron/asar; then
        echo "❌ Failed to install Electron and/or Asar locally."
        cd "$PROJECT_ROOT"
        exit 1
    fi
    echo "✓ Electron and Asar installation command finished."
else
    echo "✓ Local Electron distribution and Asar binary already present."
fi

if [ -d "$ELECTRON_DIST_PATH" ]; then
    echo "✓ Found Electron distribution directory at $ELECTRON_DIST_PATH."
    CHOSEN_ELECTRON_MODULE_PATH="$(realpath "$WORK_DIR/node_modules/electron")" # Path inside build_dev
    echo "✓ Setting Electron module path for copying (in Part 2) to $CHOSEN_ELECTRON_MODULE_PATH."
else
    echo "❌ Failed to find Electron distribution directory at '$ELECTRON_DIST_PATH' after installation attempt."
    cd "$PROJECT_ROOT"; exit 1
fi

if [ -f "$ASAR_BIN_PATH" ]; then
    ASAR_EXEC="$(realpath "$ASAR_BIN_PATH")" # Path inside build_dev
    echo "✓ Found local Asar binary at $ASAR_EXEC."
else
    echo "❌ Failed to find Asar binary at '$ASAR_BIN_PATH' after installation attempt."
    cd "$PROJECT_ROOT"; exit 1
fi

cd "$PROJECT_ROOT" # Go back to project root before next steps
if [ -z "$CHOSEN_ELECTRON_MODULE_PATH" ] || [ ! -d "$CHOSEN_ELECTRON_MODULE_PATH" ]; then
     echo "❌ Critical error: Could not resolve a valid Electron module path."
     exit 1
fi
if [ -z "$ASAR_EXEC" ] || [ ! -f "$ASAR_EXEC" ]; then
     echo "❌ Critical error: Could not resolve a valid Asar executable path."
     exit 1
fi
echo "Using Electron module path (relative to build_dev): $CHOSEN_ELECTRON_MODULE_PATH"
echo "Using asar executable (relative to build_dev): $ASAR_EXEC"


# --- Download the latest Claude executable ---
echo -e "\033[1;36m--- Download Claude Executable (to $WORK_DIR) ---\033[0m"
echo "📥 Downloading Claude Desktop installer for $ARCHITECTURE..."
CLAUDE_EXE_PATH="$WORK_DIR/$CLAUDE_EXE_FILENAME"
if ! wget -O "$CLAUDE_EXE_PATH" "$CLAUDE_DOWNLOAD_URL"; then
    echo "❌ Failed to download Claude Desktop installer from $CLAUDE_DOWNLOAD_URL"
    exit 1
fi
echo "✓ Download complete: $CLAUDE_EXE_FILENAME"

# --- Extract Resources ---
echo -e "\033[1;36m--- Extract Claude Resources (in $WORK_DIR) ---\033[0m"
echo "📦 Extracting resources from $CLAUDE_EXE_FILENAME into separate directory..."
CLAUDE_EXTRACT_DIR="$WORK_DIR/claude-extract"
mkdir -p "$CLAUDE_EXTRACT_DIR"
if ! 7z x -y "$CLAUDE_EXE_PATH" -o"$CLAUDE_EXTRACT_DIR"; then
    echo "❌ Failed to extract installer"
    cd "$PROJECT_ROOT"; exit 1
fi

cd "$CLAUDE_EXTRACT_DIR" # Change into the extract dir to find files
NUPKG_PATH_RELATIVE=$(find . -maxdepth 1 -name "AnthropicClaude-*.nupkg" | head -1)
if [ -z "$NUPKG_PATH_RELATIVE" ]; then
    echo "❌ Could not find AnthropicClaude nupkg file in $CLAUDE_EXTRACT_DIR"
    cd "$PROJECT_ROOT"; exit 1
fi
NUPKG_PATH="$CLAUDE_EXTRACT_DIR/$NUPKG_PATH_RELATIVE"
echo "Found nupkg: $NUPKG_PATH_RELATIVE (in $CLAUDE_EXTRACT_DIR)"

VERSION=$(echo "$NUPKG_PATH_RELATIVE" | LC_ALL=C grep -oP 'AnthropicClaude-\K[0-9]+\.[0-9]+\.[0-9]+(?=-full|-arm64-full)')
if [ -z "$VERSION" ]; then
    echo "❌ Could not extract version from nupkg filename: $NUPKG_PATH_RELATIVE"
    cd "$PROJECT_ROOT"; exit 1
fi
echo "✓ Detected Claude version: $VERSION"

if ! 7z x -y "$NUPKG_PATH_RELATIVE"; then
    echo "❌ Failed to extract nupkg"
    cd "$PROJECT_ROOT"; exit 1
fi
echo "✓ Resources extracted from nupkg"

# --- Process Icons ---
EXE_RELATIVE_PATH="lib/net45/claude.exe" # Check if this path is correct for arm64 too
if [ ! -f "$EXE_RELATIVE_PATH" ]; then
    echo "❌ Cannot find claude.exe at expected path within extraction dir: $CLAUDE_EXTRACT_DIR/$EXE_RELATIVE_PATH"
    cd "$PROJECT_ROOT"; exit 1
fi
echo "🎨 Processing icons from $EXE_RELATIVE_PATH..."
if ! wrestool -x -t 14 "$EXE_RELATIVE_PATH" -o claude.ico; then
    echo "❌ Failed to extract icons from exe"
    cd "$PROJECT_ROOT"; exit 1
fi

if ! icotool -x claude.ico; then
    echo "❌ Failed to convert icons"
    cd "$PROJECT_ROOT"; exit 1
fi
cp claude_*.png "$WORK_DIR/" # Copy icons to WORK_DIR (build_dev)
echo "✓ Icons processed and copied to $WORK_DIR"

cd "$PROJECT_ROOT" # Go back to project root before next steps

# --- Process app.asar (Initial Steps) ---
echo -e "\033[1;36m--- Process app.asar (Initial - in $APP_STAGING_DIR) ---\033[0m"
echo "Copying app.asar and unpacked resources to staging ($APP_STAGING_DIR)..."
cp "$CLAUDE_EXTRACT_DIR/lib/net45/resources/app.asar" "$APP_STAGING_DIR/"
cp -a "$CLAUDE_EXTRACT_DIR/lib/net45/resources/app.asar.unpacked" "$APP_STAGING_DIR/"

echo "Extracting app.asar contents..."
cd "$APP_STAGING_DIR"
"$ASAR_EXEC" extract app.asar app.asar.contents # Use ASAR_EXEC from build_dev

echo "Creating stub native module..."
mkdir -p app.asar.contents/node_modules/claude-native # Ensure dir exists before writing file
cat > app.asar.contents/node_modules/claude-native/index.js << EOF
// Stub implementation of claude-native using KeyboardKey enum values
const KeyboardKey = { Backspace: 43, Tab: 280, Enter: 261, Shift: 272, Control: 61, Alt: 40, CapsLock: 56, Escape: 85, Space: 276, PageUp: 251, PageDown: 250, End: 83, Home: 154, LeftArrow: 175, UpArrow: 282, RightArrow: 262, DownArrow: 81, Delete: 79, Meta: 187 };
Object.freeze(KeyboardKey);
module.exports = { getWindowsVersion: () => "10.0.0", setWindowEffect: () => {}, removeWindowEffect: () => {}, getIsMaximized: () => false, flashFrame: () => {}, clearFlashFrame: () => {}, showNotification: () => {}, setProgressBar: () => {}, clearProgressBar: () => {}, setOverlayIcon: () => {}, clearOverlayIcon: () => {}, KeyboardKey };
EOF

echo "Copying additional resources (Tray icons, i18n)..."
mkdir -p app.asar.contents/resources
mkdir -p app.asar.contents/resources/i18n
cp "$CLAUDE_EXTRACT_DIR/lib/net45/resources/Tray"* app.asar.contents/resources/
cp "$CLAUDE_EXTRACT_DIR/lib/net45/resources/"*-*.json app.asar.contents/resources/i18n/

echo "Switching win32 detection flag to linux to enable titlebar"

echo "Current working directory: '$PWD'"

SEARCH_BASE="app.asar.contents/.vite/renderer/main_window/assets"
TARGET_PATTERN="main-*.js"

echo "Searching for '$TARGET_PATTERN' within '$SEARCH_BASE'..."
# Find the target file recursively (ensure only one matches)
# Use -type f to ensure we only find files
TARGET_FILES=$(find "$SEARCH_BASE" -type f -name "$TARGET_PATTERN")
# Count non-empty lines to get the number of files found
NUM_FILES=$(echo "$TARGET_FILES" | grep -c .)

if [ "$NUM_FILES" -eq 0 ]; then
  echo "Error: No file matching '$TARGET_PATTERN' found within '$SEARCH_BASE'." >&2
  # Consider exiting: exit 1
elif [ "$NUM_FILES" -gt 1 ]; then
  echo "Error: Expected exactly one file matching '$TARGET_PATTERN' within '$SEARCH_BASE', but found $NUM_FILES." >&2
  echo "Found files:" >&2
  echo "$TARGET_FILES" >&2
  # Consider exiting: exit 1
else
  # Exactly one file found
  TARGET_FILE="$TARGET_FILES" # Assign the found file path
  echo "Found target file: $TARGET_FILE"
  echo "Attempting to replace 'win32' with 'linux' in $TARGET_FILE..."
  sed -i 's/win32/linux/g' "$TARGET_FILE"

  # Verification
  if grep -q 'linux' "$TARGET_FILE" && ! grep -q 'win32' "$TARGET_FILE"; then
    echo "Successfully replaced 'win32' with 'linux' in $TARGET_FILE"
  else
    echo "Error: Failed to replace 'win32' with 'linux' in $TARGET_FILE. Check file contents." >&2
    # Consider exiting: exit 1
  fi
fi

# --- End of Part 1 ---
echo -e "\033[1;36m--- Saving Build State for Part 2 ---\033[0m"
BUILD_VARS_FILE="$WORK_DIR/.build_vars" # Save vars file inside build_dev
echo "Saving build variables to $BUILD_VARS_FILE"
{
    echo "export VERSION=\"$VERSION\""
    echo "export ARCHITECTURE=\"$ARCHITECTURE\""
    # Save base names relative to PROJECT_ROOT for reconstruction in Part 2
    echo "export BUILD_DEV_DIR_BASENAME=\"$(basename "$BUILD_DEV_DIR")\"" # e.g., "build_dev"
    echo "export APP_STAGING_DIR_BASENAME=\"$(basename "$APP_STAGING_DIR")\"" # e.g., "electron-app"
    echo "export PROJECT_ROOT=\"$PROJECT_ROOT\"" # Keep absolute project root
    echo "export PACKAGE_NAME=\"$PACKAGE_NAME\""
    echo "export MAINTAINER=\"$MAINTAINER\""
    echo "export DESCRIPTION=\"$DESCRIPTION\""
    echo "export BUILD_FORMAT=\"$BUILD_FORMAT\""
    echo "export PERFORM_CLEANUP=\"$PERFORM_CLEANUP\""
    # Save relative paths for executables/modules within build_dev
    echo "export ASAR_EXEC_RELPATH=\"$(realpath --relative-to="$WORK_DIR" "$ASAR_EXEC")\"" # e.g., node_modules/.bin/asar
    echo "export CHOSEN_ELECTRON_MODULE_RELPATH=\"$(realpath --relative-to="$WORK_DIR" "$CHOSEN_ELECTRON_MODULE_PATH")\"" # e.g., node_modules/electron
} > "$BUILD_VARS_FILE"
echo "✓ Variables saved."

cd "$PROJECT_ROOT" # Ensure we are back at project root

echo -e "\n\033[1;32m✅ Build Part 1 finished.\033[0m"
echo "Development build artifacts prepared in: $BUILD_DEV_DIR"
echo "You can now modify files within $BUILD_DEV_DIR."
echo "Run build_dev_part2.sh to copy to 'build' and continue the final packaging process."

exit 0