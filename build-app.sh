#!/bin/bash
#
# build-app.sh - build Codex Usage Tracker and package it as a .app bundle.
#
# Usage:
#   ./build-app.sh          build + bundle into build/Codex Usage.app
#   ./build-app.sh run      build + bundle, then (re)launch the app
#   ./build-app.sh install  build + bundle, then copy to /Applications
#
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Codex Usage"
BUNDLE_ID="com.local.codex-usage-tracker"
EXECUTABLE="CodexUsageTracker"
BUILD_DIR="build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
VERSION="1.0"

echo "[1/4] Building release binary..."
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${EXECUTABLE}"
if [[ ! -f "${BIN_PATH}" ]]; then
    echo "ERROR: build product not found at ${BIN_PATH}" >&2
    exit 1
fi

echo "[2/4] Assembling ${APP_DIR} ..."
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${EXECUTABLE}"

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>     <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>      <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>      <string>${EXECUTABLE}</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundleVersion</key>         <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key> <true/>
</dict>
</plist>
PLIST

echo "[3/4] Ad-hoc code signing..."
codesign --force --sign - "${APP_DIR}" >/dev/null 2>&1 || \
    echo "  (codesign skipped - app will still run locally)"

echo "[4/4] Built: ${APP_DIR}"

case "${1:-}" in
    run)
        echo "Relaunching..."
        pkill -f "${APP_DIR}/Contents/MacOS/${EXECUTABLE}" 2>/dev/null || true
        sleep 0.3
        open "${APP_DIR}"
        ;;
    install)
        echo "Installing to /Applications..."
        pkill -f "Codex Usage.app/Contents/MacOS/${EXECUTABLE}" 2>/dev/null || true
        sleep 0.4
        rm -rf "/Applications/${APP_NAME}.app"
        cp -R "${APP_DIR}" "/Applications/"
        codesign --force --sign - "/Applications/${APP_NAME}.app" >/dev/null 2>&1 || true
        echo "Installed: /Applications/${APP_NAME}.app"
        open "/Applications/${APP_NAME}.app"
        ;;
esac
