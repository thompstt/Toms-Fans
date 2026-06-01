#!/bin/bash
# build-release.sh — Build Tom's Fans in Release configuration.
# Usage: ./build-release.sh
#
# Produces an ad-hoc-signed app bundle for local use. No Apple Developer
# account or signing identity is required.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Building Tom's Fans (Release)…"
xcodebuild -project "$SCRIPT_DIR/Tom's Fans.xcodeproj" \
    -scheme "Tom's Fans" \
    -configuration Release \
    build

APP_DIR=$(xcodebuild -project "$SCRIPT_DIR/Tom's Fans.xcodeproj" \
    -showBuildSettings -scheme "Tom's Fans" -configuration Release 2>/dev/null \
    | sed -n 's/^[[:space:]]*BUILT_PRODUCTS_DIR = //p' | head -1)

echo ""
echo "✅ Build complete."
echo "   App: $APP_DIR/Tom's Fans.app"
echo ""
echo "Install the privileged helper with EITHER:"
echo "   • Launch the app and click 'Install Helper' (approve in System Settings), or"
echo "   • sudo ./install-helper.sh"
