#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE="$BUILD_DIR/XDrive.app"

echo "=== Building XDrive (4 Executables + OrbitCore) ==="
cd "$PROJECT_DIR"
swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Extensions/OrbitFS.appex/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/PlugIns/OrbitFinder.appex/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Library/LaunchDaemons"

# 1. Copy Main App & Privileged LaunchDaemon Helper
cp "$BIN_DIR/XDrive" "$APP_BUNDLE/Contents/MacOS/XDrive"
cp "$BIN_DIR/OrbitMountHelper" "$APP_BUNDLE/Contents/MacOS/OrbitMountHelper"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/com.letcontactabhi.orbit.MountHelper.plist" \
   "$APP_BUNDLE/Contents/Library/LaunchDaemons/com.letcontactabhi.orbit.MountHelper.plist"

# 2. Copy FSKit FileSystem Extension (OrbitFS.appex)
cp "$BIN_DIR/OrbitFS" "$APP_BUNDLE/Contents/Extensions/OrbitFS.appex/Contents/MacOS/OrbitFS"
cp "$PROJECT_DIR/Resources/OrbitFS-Info.plist" "$APP_BUNDLE/Contents/Extensions/OrbitFS.appex/Contents/Info.plist"

# 3. Copy Finder Sync Extension (OrbitFinder.appex)
cp "$BIN_DIR/OrbitFinder" "$APP_BUNDLE/Contents/PlugIns/OrbitFinder.appex/Contents/MacOS/OrbitFinder"
cp "$PROJECT_DIR/Resources/OrbitFinder-Info.plist" "$APP_BUNDLE/Contents/PlugIns/OrbitFinder.appex/Contents/Info.plist"

# 4. Ad-hoc sign all nested extensions, helpers, and main bundle
codesign --force --sign - "$APP_BUNDLE/Contents/Extensions/OrbitFS.appex"
codesign --force --sign - "$APP_BUNDLE/Contents/PlugIns/OrbitFinder.appex"
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/OrbitMountHelper"
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

echo "=== Build & Bundle Complete: $APP_BUNDLE ==="

