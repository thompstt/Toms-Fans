#!/bin/bash
# install-helper.sh — Manually install the privileged helper daemon for development.
# Usage: sudo ./install-helper.sh
#
# This copies the helper binary to /Library/PrivilegedHelperTools/ and
# the launchd plist to /Library/LaunchDaemons/, then loads it.
# The helper will run as root and listen for XPC connections from the app.

set -e

if [ "$EUID" -ne 0 ]; then
    echo "This script must be run with sudo:"
    echo "  sudo ./install-helper.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve the invoking user's environment, since under sudo $HOME and the
# Xcode/DerivedData context belong to root, not the developer.
RUN_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$RUN_USER")
DERIVED_DATA="$REAL_HOME/Library/Developer/Xcode/DerivedData"

# Ask xcodebuild which DerivedData directory matches THIS project,
# so a worktree's install doesn't accidentally pick the parent repo's build.
# Run as the invoking user so xcodebuild resolves the right DerivedData.
PROJECT_BUILD_DIR=$(sudo -u "$RUN_USER" xcodebuild -project "$SCRIPT_DIR/Tom's Fans.xcodeproj" -showBuildSettings -scheme "Tom's Fans" -configuration Release 2>/dev/null \
    | sed -n 's/^[[:space:]]*BUILT_PRODUCTS_DIR = //p' | head -1)
HELPER_PATH=""
if [ -n "$PROJECT_BUILD_DIR" ] && [ -f "$PROJECT_BUILD_DIR/com.tomsfans.helper" ]; then
    HELPER_PATH="$PROJECT_BUILD_DIR/com.tomsfans.helper"
fi

# Fall back to the most-recently-modified helper anywhere in DerivedData.
# Use -print0/-0 so paths containing spaces or apostrophes (e.g. "Tom's Fans")
# don't break xargs with "unterminated quote".
if [ -z "$HELPER_PATH" ]; then
    HELPER_PATH=$(find "$DERIVED_DATA" -name "com.tomsfans.helper" -type f -path "*/Release/*" -print0 2>/dev/null \
        | xargs -0 stat -f "%m %N" 2>/dev/null \
        | sort -nr | head -1 | cut -d' ' -f2-)
fi

if [ -z "$HELPER_PATH" ]; then
    echo "Error: Could not find built helper binary."
    echo "Build the Release app first: ./build-release.sh (or Product > Build in Xcode)."
    exit 1
fi

echo "Found helper at: $HELPER_PATH"

# Unload existing daemon if running
if launchctl list | grep -q "com.tomsfans.helper"; then
    echo "Stopping existing helper..."
    launchctl unload /Library/LaunchDaemons/com.tomsfans.helper.plist 2>/dev/null || true
fi

# Copy files
echo "Installing helper binary..."
mkdir -p /Library/PrivilegedHelperTools
cp -f "$HELPER_PATH" /Library/PrivilegedHelperTools/com.tomsfans.helper
chmod 755 /Library/PrivilegedHelperTools/com.tomsfans.helper
chown root:wheel /Library/PrivilegedHelperTools/com.tomsfans.helper

echo "Installing launchd plist..."
cp -f "$SCRIPT_DIR/Helper/launchd-system.plist" /Library/LaunchDaemons/com.tomsfans.helper.plist
chmod 644 /Library/LaunchDaemons/com.tomsfans.helper.plist
chown root:wheel /Library/LaunchDaemons/com.tomsfans.helper.plist

# Load the daemon
echo "Loading helper daemon..."
launchctl load /Library/LaunchDaemons/com.tomsfans.helper.plist

# Verify
if launchctl list | grep -q "com.tomsfans.helper"; then
    echo ""
    echo "✅ Helper installed and running!"
    echo "   Binary: /Library/PrivilegedHelperTools/com.tomsfans.helper"
    echo "   Plist:  /Library/LaunchDaemons/com.tomsfans.helper.plist"
    echo ""
    echo "You can now control fans from the app."
else
    echo ""
    echo "⚠️  Helper installed but may not be running."
    echo "   Check: sudo launchctl list | grep tomsfans"
fi
