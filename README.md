# Claude Desktop for Linux

This project provides build scripts to run Claude Desktop natively on Linux systems. It repackages the official Windows application for Debian-based and Fedora distributions, producing `.deb`, `.rpm`, or AppImage artifacts.

**Note:** This is an unofficial build script. For official support, please visit [Anthropic's website](https://www.anthropic.com). For issues with the build script or Linux implementation, please [open an issue](https://github.com/aaddrick/claude-desktop-debian/issues) in this repository.

## Features

- **Native Linux Support**: Run Claude Desktop without virtualization or Wine
- **MCP Support**: Full Model Context Protocol integration  
  Configuration file location: `~/.config/Claude/claude_desktop_config.json`
- **System Integration**: 
  - X11 Global hotkey support (Ctrl+Alt+Space)
  - System tray integration
  - Desktop environment integration

### Screenshots

![Claude Desktop running on Linux](https://github.com/user-attachments/assets/93080028-6f71-48bd-8e59-5149d148cd45)

![Global hotkey popup](https://github.com/user-attachments/assets/1deb4604-4c06-4e4b-b63f-7f6ef9ef28c1)

![System tray menu on KDE](https://github.com/user-attachments/assets/ba209824-8afb-437c-a944-b53fd9ecd559)

## Installation

### One-line install (recommended)

Run a single command to install or update Claude Desktop. The script auto-detects your system (Debian/Ubuntu via apt, Fedora/RHEL via dnf/yum, or falls back to AppImage), installs dependencies when needed, updates an existing install (or clean reinstalls if the update fails), and sets up automatic updates (daily systemd timer or cron):

```bash
curl -fsSL https://raw.githubusercontent.com/aaddrick/claude-desktop-debian/main/install.sh | bash
```

Options:
- Disable auto-update timer:
  ```bash
  curl -fsSL https://raw.githubusercontent.com/aaddrick/claude-desktop-debian/main/install.sh | bash -s -- --no-timer
  ```
- Update-only (no change if up-to-date; if update fails, the script cleans and reinstalls):
  ```bash
  curl -fsSL https://raw.githubusercontent.com/aaddrick/claude-desktop-debian/main/install.sh | bash -s -- --update-only
  ```

Auto-update management:
- systemd (most systems):
  - Disable: `sudo systemctl disable --now claude-desktop-update.timer`
  - Run now: `sudo systemctl start claude-desktop-update.service`
- cron fallback (when systemd not available):
  - The updater is installed at `/etc/cron.daily/claude-desktop-update`. Remove it to disable.

Using a fork:
- You can target a fork by setting environment variables before running the installer:
  ```bash
  CLAUDE_OWNER="your-github-username-or-org" CLAUDE_REPO="your-fork-repo" \
  curl -fsSL https://raw.githubusercontent.com/your-github-username-or-org/your-fork-repo/main/install.sh | bash
  ```

### Using Pre-built Releases

Download the latest `.deb`, `.rpm`, or `.AppImage` from the [Releases page](https://github.com/aaddrick/claude-desktop-debian/releases).

### Building from Source

#### Prerequisites

- Debian-based Linux distribution (Debian, Ubuntu, Linux Mint, MX Linux, etc.) OR Fedora (40/41/42)
- Git
- Basic build dependencies (automatically installed by the script using apt or dnf)

#### Build Instructions

```bash
# Clone the repository
git clone https://github.com/aaddrick/claude-desktop-debian.git
cd claude-desktop-debian

# Build a .deb package (default)
./build.sh

# Build an AppImage
./build.sh --build appimage

# Build an .rpm (Fedora)
./build.sh --build rpm

# Build with custom options
./build.sh --build deb --clean no  # Keep intermediate files
```

#### Installing the Built Package

**For .deb packages:**
```bash
sudo dpkg -i ./claude-desktop_VERSION_ARCHITECTURE.deb

# If you encounter dependency issues:
sudo apt --fix-broken install
```

**For .rpm packages (Fedora):**
```bash
# On x86_64
sudo dnf install -y ./claude-desktop_VERSION-1.x86_64.rpm

# On aarch64 (ARM64)
sudo dnf install -y ./claude-desktop_VERSION-1.aarch64.rpm
```

**For AppImages:**
```bash
# Make executable
chmod +x ./claude-desktop-*.AppImage

# Run directly
./claude-desktop-*.AppImage

# Or integrate with your system using Gear Lever
```

**Note:** AppImage login requires proper desktop integration. Use [Gear Lever](https://flathub.org/apps/it.mijorus.gearlever) or manually install the provided `.desktop` file to `~/.local/share/applications/`.

**Automatic Updates:** AppImages downloaded from GitHub releases include embedded update information and work seamlessly with Gear Lever for automatic updates. Locally-built AppImages can be manually configured for updates in Gear Lever.

## Configuration

### MCP Configuration

Model Context Protocol settings are stored in:
```
~/.config/Claude/claude_desktop_config.json
```

### Application Logs

Runtime logs are available at:
```
$HOME/claude-desktop-launcher.log
```

## Uninstallation

**For .deb packages:**
```bash
# Remove package
sudo dpkg -r claude-desktop

# Remove package and configuration
sudo dpkg -P claude-desktop
```

**For .rpm packages (Fedora):**
```bash
sudo dnf remove -y claude-desktop
```

**For AppImages:**
1. Delete the `.AppImage` file
2. Remove the `.desktop` file from `~/.local/share/applications/`
3. If using Gear Lever, use its uninstall option

**Remove user configuration (both formats):**
```bash
rm -rf ~/.config/Claude
```

## Troubleshooting

### Window Scaling Issues

If the window doesn't scale correctly on first launch:
1. Right-click the Claude Desktop tray icon
2. Select "Quit" (do not force quit)
3. Restart the application

This allows the application to save display settings properly.

### AppImage Sandbox Warning

AppImages run with `--no-sandbox` due to electron's chrome-sandbox requiring root privileges for unprivileged namespace creation. This is a known limitation of AppImage format with Electron applications.

For enhanced security, consider:
- Using the .deb package instead
- Running the AppImage within a separate sandbox (e.g., bubblewrap)
- Using Gear Lever's integrated AppImage management for better isolation

## Technical Details

### How It Works

Claude Desktop is an Electron application distributed for Windows. This project:

1. Downloads the official Windows installer
2. Extracts application resources
3. Replaces Windows-specific native modules with Linux-compatible implementations
4. Repackages as either:
   - **Debian package**: Standard system package with full integration
   - **Fedora RPM package**: Standard RPM with full desktop integration (dnf install)
   - **AppImage**: Portable, self-contained executable

### Build Process

The build script (`build.sh`) handles:
- Dependency checking and installation
- Resource extraction from Windows installer
- Icon processing for Linux desktop standards
- Native module replacement
- Package generation based on selected format

### Updating for New Releases

- The build script automatically detects system architecture and downloads the appropriate version. If Claude Desktop's download URLs change, update the `CLAUDE_DOWNLOAD_URL` variables in [build.sh](build.sh:1).
- Continuous delivery: A nightly CI job checks the upstream Windows installer for a new version. When a new version is detected, it creates a new git tag `vX.Y.Z`, which triggers the release workflow to build and publish RPMs for Fedora 40/41 (CI) on x86_64 and aarch64. Local builds are validated on Fedora 42 as well.

## Acknowledgments

This project was inspired by [k3d3's claude-desktop-linux-flake](https://github.com/k3d3/claude-desktop-linux-flake) and their [Reddit post](https://www.reddit.com/r/ClaudeAI/comments/1hgsmpq/i_successfully_ran_claude_desktop_natively_on/) about running Claude Desktop natively on Linux.

Special thanks to:
- **k3d3** for the original NixOS implementation and native bindings insights
- **[emsi](https://github.com/emsi/claude-desktop)** for the title bar fix and alternative implementation approach

For NixOS users, please refer to [k3d3's repository](https://github.com/k3d3/claude-desktop-linux-flake) for a Nix-specific implementation.

## License

The build scripts in this repository are dual-licensed under:
- MIT License (see [LICENSE-MIT](LICENSE-MIT))
- Apache License 2.0 (see [LICENSE-APACHE](LICENSE-APACHE))

The Claude Desktop application itself is subject to [Anthropic's Consumer Terms](https://www.anthropic.com/legal/consumer-terms).

## Contributing

Contributions are welcome! By submitting a contribution, you agree to license it under the same dual-license terms as this project.


## Fedora (dnf) Quick Start

- Install a prebuilt RPM:
  - x86_64:
    ```bash
    sudo dnf install -y ./claude-desktop_VERSION-1.x86_64.rpm
    ```
  - aarch64:
    ```bash
    sudo dnf install -y ./claude-desktop_VERSION-1.aarch64.rpm
    ```
- Uninstall:
  ```bash
  sudo dnf remove -y claude-desktop
  ```

## Building from Source on Fedora

- Prerequisites (installed automatically by the script if missing):
  ```bash
  sudo dnf install -y p7zip p7zip-plugins wget icoutils ImageMagick rpm-build desktop-file-utils
  ```
- Build RPM:
  ```bash
  ./build.sh --build rpm
  ```
  - Target a specific architecture (for cross-builds in CI):
    ```bash
    ./build.sh --build rpm --target-arch amd64   # for x86_64
    ./build.sh --build rpm --target-arch arm64   # for aarch64
    ```

## CI for Continuous Fedora Releases

- Tag-based releases: pushing a tag like `vX.Y.Z` triggers the RPM build matrix for Fedora 40 and 41 on x86_64 and aarch64 and attaches artifacts to the GitHub Release.
  - Create a release tag:
    ```bash
    git tag vX.Y.Z
    git push origin vX.Y.Z
    ```
- Nightly auto-release:
  - A scheduled workflow checks the upstream Windows installer daily using [scripts/get-upstream-version.sh](scripts/get-upstream-version.sh). If a new version is found, it pushes `vX.Y.Z`, which triggers the release workflow automatically.
- Manual run:
  - From GitHub Actions, run the “Build and Release RPMs” workflow (workflow_dispatch) to build artifacts without publishing a tag. Artifacts will be available in the Actions run.

### CI runner prerequisites and notes

- Ubuntu runner prerequisites (installed by workflows):
  - `libfuse2` (AppImage runtime)
  - `icoutils` (wrestool/icotool for icon extraction)
  - `imagemagick` (convert utility)
  - `p7zip-full`, `wget`
- Fedora container steps are hardened with DNF fastestmirror, retries, and refresh for reliability.
- The scheduled “Check Claude Desktop Version” workflow requires a Personal Access Token:
  - Create a PAT with `repo` and `workflow` scopes and set it as the `GH_PAT` repository secret.
  - When `GH_PAT` is not configured, the workflow will skip tag and release publication gracefully while still detecting updates.
