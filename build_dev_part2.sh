#!/bin/bash
set -euo pipefail

echo -e "\033[1;36m--- Build Part 2: Copying Dev State and Finalizing ---\033[0m"

rm ./claude-desktop_0.9.1_amd64.deb

# Define Project Root early
PROJECT_ROOT="$(pwd)"
# Define build_dev path based on expected structure from Part 1
BUILD_DEV_DIR_BASENAME_EXPECTED="build_dev" # Expected basename
BUILD_DEV_DIR="$PROJECT_ROOT/$BUILD_DEV_DIR_BASENAME_EXPECTED"
BUILD_VARS_FILE="$BUILD_DEV_DIR/.build_vars"

# --- Load Variables from Part 1 (inside build_dev) ---
if [ ! -f "$BUILD_VARS_FILE" ]; then
    echo "❌ Build variables file not found: $BUILD_VARS_FILE"
    echo "   Run build_dev_part1.sh script first."
    exit 1
fi
echo "Loading build variables from $BUILD_VARS_FILE..."
# shellcheck disable=SC1090
source "$BUILD_VARS_FILE"
echo "✓ Variables loaded."

# --- Define Final Build Directory ---
FINAL_BUILD_DIR="$PROJECT_ROOT/build" # The final build directory name
echo "Target final build directory: $FINAL_BUILD_DIR"

# --- Reconstruct Paths for Final Build ---
# These paths will point inside the FINAL_BUILD_DIR after copying
WORK_DIR="$FINAL_BUILD_DIR"
APP_STAGING_DIR="$WORK_DIR/$APP_STAGING_DIR_BASENAME" # e.g., /path/to/project/build/electron-app
ASAR_EXEC="$WORK_DIR/$ASAR_EXEC_RELPATH" # e.g., /path/to/project/build/node_modules/.bin/asar
CHOSEN_ELECTRON_MODULE_PATH="$WORK_DIR/$CHOSEN_ELECTRON_MODULE_RELPATH" # e.g., /path/to/project/build/node_modules/electron

echo "Final WORK_DIR: $WORK_DIR"
echo "Final APP_STAGING_DIR: $APP_STAGING_DIR"
echo "Final ASAR_EXEC: $ASAR_EXEC"
echo "Final CHOSEN_ELECTRON_MODULE_PATH: $CHOSEN_ELECTRON_MODULE_PATH"
echo "Using VERSION: $VERSION"
echo "Using ARCHITECTURE: $ARCHITECTURE"
echo "Using BUILD_FORMAT: $BUILD_FORMAT"
echo "Using PERFORM_CLEANUP: $PERFORM_CLEANUP"

# --- Prepare Final Build Directory ---
# Check if build_dev exists (source of copy)
if [ ! -d "$BUILD_DEV_DIR" ]; then
    echo "❌ Source development build directory not found: $BUILD_DEV_DIR"
    echo "   Run build_dev_part1.sh script first."
    exit 1
fi

# Check if final build directory exists, remove if it does
if [ -d "$FINAL_BUILD_DIR" ]; then
    echo "Found existing final build directory ($FINAL_BUILD_DIR), removing it..."
    if ! rm -rf "$FINAL_BUILD_DIR"; then
        echo "❌ Failed to remove existing final build directory."
        exit 1
    fi
    echo "✓ Existing final build directory removed."
fi

# Copy build_dev contents to the final build directory using rsync
echo "Copying $BUILD_DEV_DIR contents to $FINAL_BUILD_DIR..."
mkdir -p "$FINAL_BUILD_DIR" # Ensure target exists
if rsync -a --delete --exclude '.build_vars' "$BUILD_DEV_DIR/" "$FINAL_BUILD_DIR/"; then
    echo "✓ Copied development build contents to final build directory."
else
    echo "❌ Failed to copy development build contents using rsync."
    exit 1
fi

# --- Resume Build Process in Final Build Directory: ASAR Packing ---
echo -e "\033[1;36m--- Resume: Packing app.asar in $APP_STAGING_DIR ---\033[0m"
# Change to APP_STAGING_DIR (inside final build dir) for asar packing
if ! cd "$APP_STAGING_DIR"; then
    echo "❌ Failed to change directory to $APP_STAGING_DIR"
    exit 1
fi

echo "Packing app.asar from app.asar.contents..."
if [ ! -d "app.asar.contents" ]; then
    echo "❌ app.asar.contents directory not found in $APP_STAGING_DIR. Cannot pack."
    cd "$PROJECT_ROOT"; exit 1
fi
# Use the ASAR_EXEC path reconstructed for the final build dir
if ! "$ASAR_EXEC" pack app.asar.contents app.asar; then
    echo "❌ Failed to pack app.asar."
    cd "$PROJECT_ROOT"; exit 1
fi
echo "✓ app.asar packed."
rm -rf app.asar.contents # Clean up extracted contents
echo "✓ Cleaned up app.asar.contents."

# --- Resume: Stub Native Module in Unpacked ---
echo "Creating stub native module in unpacked directory ($APP_STAGING_DIR)..."
mkdir -p "$APP_STAGING_DIR/app.asar.unpacked/node_modules/claude-native"
cat > "$APP_STAGING_DIR/app.asar.unpacked/node_modules/claude-native/index.js" << EOF
// Stub implementation of claude-native using KeyboardKey enum values
const KeyboardKey = { Backspace: 43, Tab: 280, Enter: 261, Shift: 272, Control: 61, Alt: 40, CapsLock: 56, Escape: 85, Space: 276, PageUp: 251, PageDown: 250, End: 83, Home: 154, LeftArrow: 175, UpArrow: 282, RightArrow: 262, DownArrow: 81, Delete: 79, Meta: 187 };
Object.freeze(KeyboardKey);
module.exports = { getWindowsVersion: () => "10.0.0", setWindowEffect: () => {}, removeWindowEffect: () => {}, getIsMaximized: () => false, flashFrame: () => {}, clearFlashFrame: () => {}, showNotification: () => {}, setProgressBar: () => {}, clearProgressBar: () => {}, setOverlayIcon: () => {}, clearOverlayIcon: () => {}, KeyboardKey };
EOF
echo "✓ Stub native module created in unpacked directory."

# --- Resume: Copy Electron Installation ---
echo "Copying chosen electron installation to staging area ($APP_STAGING_DIR)..."
mkdir -p "$APP_STAGING_DIR/node_modules/"
ELECTRON_DIR_NAME=$(basename "$CHOSEN_ELECTRON_MODULE_PATH") # Basename is the same
echo "Copying from $CHOSEN_ELECTRON_MODULE_PATH to $APP_STAGING_DIR/node_modules/"
# Note: Electron was already copied from build_dev, this step might be redundant
# if rsync copied node_modules correctly. Let's ensure it's there.
if [ ! -d "$APP_STAGING_DIR/node_modules/$ELECTRON_DIR_NAME" ]; then
    echo "Electron module not found after rsync, attempting copy again..."
    # This path should point to the electron install *within* the final build dir now
    SOURCE_ELECTRON_PATH_IN_FINAL_BUILD="$WORK_DIR/$CHOSEN_ELECTRON_MODULE_RELPATH"
    if ! cp -a "$SOURCE_ELECTRON_PATH_IN_FINAL_BUILD" "$APP_STAGING_DIR/node_modules/"; then
        echo "❌ Failed to copy Electron module into final staging area."
        cd "$PROJECT_ROOT"; exit 1
    fi
else
    echo "✓ Electron module already present in final staging area."
fi

STAGED_ELECTRON_BIN="$APP_STAGING_DIR/node_modules/$ELECTRON_DIR_NAME/dist/electron"
if [ -f "$STAGED_ELECTRON_BIN" ]; then
    echo "Setting executable permission on staged Electron binary: $STAGED_ELECTRON_BIN"
    chmod +x "$STAGED_ELECTRON_BIN"
else
    echo "Warning: Staged Electron binary not found at expected path: $STAGED_ELECTRON_BIN"
fi
echo "✓ Electron installation prepared in $APP_STAGING_DIR"

# --- Change back to Project Root ---
cd "$PROJECT_ROOT"

# --- Call Packaging Script ---
echo -e "\033[1;36m--- Call Packaging Script (using $FINAL_BUILD_DIR) ---\033[0m"
FINAL_OUTPUT_PATH="" FINAL_DESKTOP_FILE_PATH=""
if [ "$BUILD_FORMAT" = "deb" ]; then
    echo "📦 Calling Debian packaging script for $ARCHITECTURE..."
    chmod +x scripts/build-deb-package.sh
    # Pass the FINAL_BUILD_DIR (WORK_DIR) and APP_STAGING_DIR within it
    if ! scripts/build-deb-package.sh \
        "$VERSION" "$ARCHITECTURE" "$WORK_DIR" "$APP_STAGING_DIR" \
        "$PACKAGE_NAME" "$MAINTAINER" "$DESCRIPTION"; then
        echo "❌ Debian packaging script failed."
        exit 1
    fi
    DEB_FILE=$(find "$WORK_DIR" -maxdepth 1 -name "${PACKAGE_NAME}_${VERSION}_${ARCHITECTURE}.deb" | head -n 1)
    echo "✓ Debian Build complete!"
    if [ -n "$DEB_FILE" ] && [ -f "$DEB_FILE" ]; then
        FINAL_OUTPUT_PATH="./$(basename "$DEB_FILE")" # Output to project root
        mv "$DEB_FILE" "$FINAL_OUTPUT_PATH"
        echo "Package created at: $FINAL_OUTPUT_PATH"
    else
        echo "Warning: Could not determine final .deb file path from $WORK_DIR for ${ARCHITECTURE}."
        FINAL_OUTPUT_PATH="Not Found"
    fi

elif [ "$BUILD_FORMAT" = "appimage" ]; then
    echo "📦 Calling AppImage packaging script for $ARCHITECTURE..."
    chmod +x scripts/build-appimage.sh
    # Pass the FINAL_BUILD_DIR (WORK_DIR) and APP_STAGING_DIR within it
    if ! scripts/build-appimage.sh \
        "$VERSION" "$ARCHITECTURE" "$WORK_DIR" "$APP_STAGING_DIR" "$PACKAGE_NAME"; then
        echo "❌ AppImage packaging script failed."
        exit 1
    fi
    APPIMAGE_FILE=$(find "$WORK_DIR" -maxdepth 1 -name "${PACKAGE_NAME}-${VERSION}-${ARCHITECTURE}.AppImage" | head -n 1)
    echo "✓ AppImage Build complete!"
    if [ -n "$APPIMAGE_FILE" ] && [ -f "$APPIMAGE_FILE" ]; then
        FINAL_OUTPUT_PATH="./$(basename "$APPIMAGE_FILE")" # Output to project root
        mv "$APPIMAGE_FILE" "$FINAL_OUTPUT_PATH"
        echo "Package created at: $FINAL_OUTPUT_PATH"

        echo -e "\033[1;36m--- Generate .desktop file for AppImage ---\033[0m"
        FINAL_DESKTOP_FILE_PATH="./${PACKAGE_NAME}-appimage.desktop"
        echo "📝 Generating .desktop file for AppImage at $FINAL_DESKTOP_FILE_PATH..."
        cat > "$FINAL_DESKTOP_FILE_PATH" << EOF
[Desktop Entry]
Name=Claude (AppImage)
Comment=Claude Desktop (AppImage Version $VERSION)
Exec=$(basename "$FINAL_OUTPUT_PATH") %u
Icon=claude-desktop
Type=Application
Terminal=false
Categories=Office;Utility;Network;
MimeType=x-scheme-handler/claude;
StartupWMClass=Claude
X-AppImage-Version=$VERSION
X-AppImage-Name=Claude Desktop (AppImage)
EOF
        echo "✓ .desktop file generated."

    else
        echo "Warning: Could not determine final .AppImage file path from $WORK_DIR for ${ARCHITECTURE}."
        FINAL_OUTPUT_PATH="Not Found"
    fi
fi


# --- Cleanup ---
echo -e "\033[1;36m--- Cleanup ---\033[0m"
if [ "$PERFORM_CLEANUP" = true ]; then
    echo "🧹 Cleaning up final build directory: $FINAL_BUILD_DIR..."
    if rm -rf "$FINAL_BUILD_DIR"; then
        echo "✓ Cleanup complete ($FINAL_BUILD_DIR removed)."
    else
        echo "⚠️ Cleanup command (rm -rf $FINAL_BUILD_DIR) failed."
    fi
    # Optionally clean build_dev as well if desired, but the request implies keeping it
    # echo "🧹 Cleaning up development build directory: $BUILD_DEV_DIR..."
    # rm -rf "$BUILD_DEV_DIR"
else
    echo "Skipping cleanup of final build directory: $FINAL_BUILD_DIR."
    # echo "Skipping cleanup of development build directory: $BUILD_DEV_DIR."
fi


# --- Final Messages ---
echo "✅ Build process finished."

echo -e "\n\033[1;34m====== Next Steps ======\033[0m"
if [ "$BUILD_FORMAT" = "deb" ]; then
    if [ "$FINAL_OUTPUT_PATH" != "Not Found" ] && [ -e "$FINAL_OUTPUT_PATH" ]; then
        echo -e "📦 To install the Debian package, run:"
        echo -e "   \033[1;32msudo apt install $FINAL_OUTPUT_PATH\033[0m"
        echo -e "   (or \`sudo dpkg -i $FINAL_OUTPUT_PATH\`)"
    else
        echo -e "⚠️ Debian package file not found. Cannot provide installation instructions."
    fi
elif [ "$BUILD_FORMAT" = "appimage" ]; then
    if [ "$FINAL_OUTPUT_PATH" != "Not Found" ] && [ -e "$FINAL_OUTPUT_PATH" ]; then
        echo -e "✅ AppImage created at: \033[1;36m$FINAL_OUTPUT_PATH\033[0m"
        echo -e "\n\033[1;33mIMPORTANT:\033[0m This AppImage requires \033[1;36mAppImageLauncher\033[0m for proper desktop integration"
        echo -e "and to handle the \`claude://\` login process correctly."
        echo -e "\n🚀 To install AppImageLauncher (v2.2.0 for amd64):"
        echo -e "   1. Download:"
        echo -e "      \033[1;32mwget https://github.com/TheAssassin/AppImageLauncher/releases/download/v2.2.0/appimagelauncher_2.2.0-travis995.0f91801.bionic_amd64.deb -O /tmp/appimagelauncher.deb\033[0m"
        echo -e "       - or appropriate package from here: \033[1;34mhttps://github.com/TheAssassin/AppImageLauncher/releases/latest\033[0m"
        echo -e "   2. Install the package:"
        echo -e "      \033[1;32msudo dpkg -i /tmp/appimagelauncher.deb\033[0m"
        echo -e "   3. Fix any missing dependencies:"
        echo -e "      \033[1;32msudo apt --fix-broken install\033[0m"
        echo -e "\n   After installation, simply double-click \033[1;36m$FINAL_OUTPUT_PATH\033[0m and choose 'Integrate and run'."
    else
        echo -e "⚠️ AppImage file not found. Cannot provide usage instructions."
    fi
fi
echo -e "\033[1;34m======================\033[0m"

sudo dpkg -P claude-desktop
sudo dpkg -i ./claude-desktop_0.9.1_amd64.deb
claude-desktop

exit 0