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

# Ask xcodebuild which DerivedData directory matches THIS project,
# so a worktree's install doesn't accidentally pick the parent repo's build.
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
PROJECT_BUILD_DIR=$(xcodebuild -project "$SCRIPT_DIR/Tom's Fans.xcodeproj" -showBuildSettings -scheme "com.tomsfans.helper" -configuration Debug 2>/dev/null \
    | awk '/^[[:space:]]*BUILT_PRODUCTS_DIR =/ { print $3; exit }')
HELPER_PATH=""
if [ -n "$PROJECT_BUILD_DIR" ] && [ -f "$PROJECT_BUILD_DIR/com.tomsfans.helper" ]; then
    HELPER_PATH="$PROJECT_BUILD_DIR/com.tomsfans.helper"
fi

# Fall back to the most-recently-modified helper anywhere in DerivedData.
if [ -z "$HELPER_PATH" ]; then
    HELPER_PATH=$(find "$DERIVED_DATA" -name "com.tomsfans.helper" -type f -path "*/Debug/*" 2>/dev/null \
        | xargs -I {} stat -f "%m %N" {} \
        | sort -nr | head -1 | cut -d' ' -f2-)
fi

if [ -z "$HELPER_PATH" ]; then
    echo "Error: Could not find built helper binary."
    echo "Build the project in Xcode first (Cmd+B with 'com.tomsfans.helper' scheme)."
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
cp -f "$SCRIPT_DIR/Helper/launchd.plist" /Library/LaunchDaemons/com.tomsfans.helper.plist
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
