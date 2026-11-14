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

# 1. Copy Main App & Privileged LaunchDaemon Helper & App Icon
cp "$BIN_DIR/XDrive" "$APP_BUNDLE/Contents/MacOS/XDrive"
cp "$BIN_DIR/OrbitMountHelper" "$APP_BUNDLE/Contents/MacOS/OrbitMountHelper"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi
cp "$PROJECT_DIR/Resources/vn.xox.xdrive.MountHelper.plist" \
   "$APP_BUNDLE/Contents/Library/LaunchDaemons/vn.xox.xdrive.MountHelper.plist"

# 2. Copy FSKit FileSystem Extension (OrbitFS.appex)
cp "$BIN_DIR/OrbitFS" "$APP_BUNDLE/Contents/Extensions/OrbitFS.appex/Contents/MacOS/OrbitFS"
cp "$PROJECT_DIR/Resources/OrbitFS-Info.plist" "$APP_BUNDLE/Contents/Extensions/OrbitFS.appex/Contents/Info.plist"

# 3. Copy Finder Sync Extension (OrbitFinder.appex)
cp "$BIN_DIR/OrbitFinder" "$APP_BUNDLE/Contents/PlugIns/OrbitFinder.appex/Contents/MacOS/OrbitFinder"
cp "$PROJECT_DIR/Resources/OrbitFinder-Info.plist" "$APP_BUNDLE/Contents/PlugIns/OrbitFinder.appex/Contents/Info.plist"

# 4. Sign all nested extensions, helpers, and main bundle with Apple Developer Certificate
SIGN_IDENTITY="$(security find-identity -p codesigning -v | grep 'Apple Development:' | head -n 1 | awk -F'\"' '{print $2}' || true)"
if [ -z "$SIGN_IDENTITY" ]; then
    echo "⚠️ Không tìm thấy chứng chỉ Apple Development, fallback về ad-hoc signing (-)"
    SIGN_IDENTITY="-"
else
    echo "🔒 Đang ký ứng dụng bằng tài khoản Apple Developer: $SIGN_IDENTITY"
fi

codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --entitlements "$PROJECT_DIR/Resources/OrbitFS.entitlements" "$APP_BUNDLE/Contents/Extensions/OrbitFS.appex"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --entitlements "$PROJECT_DIR/Resources/OrbitFinder.entitlements" "$APP_BUNDLE/Contents/PlugIns/OrbitFinder.appex"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/MacOS/OrbitMountHelper"
# Không dùng --deep: nó ký lại các extension và xoá entitlements sandbox của chúng.
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --entitlements "$PROJECT_DIR/Resources/XDrive-DeveloperID.entitlements" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
echo "✅ Đã xác minh tính toàn vẹn chữ ký thành công:"
codesign -dvvv "$APP_BUNDLE" 2>&1 | grep -E "Authority|TeamIdentifier|Identifier"

# Phát hành ngoài App Store: XCODE_NOTARIZE_TEAM=<team-id> ký lại bằng Developer ID
# trên đám mây của Xcode rồi notarize + staple.
if [ -n "${XCODE_NOTARIZE_TEAM:-}" ]; then
    "$SCRIPT_DIR/notarize-with-xcode.sh" "$APP_BUNDLE" "$XCODE_NOTARIZE_TEAM"
fi

if [ "${SKIP_INSTALL:-0}" = "1" ]; then
    echo "=== Build Complete: $APP_BUNDLE (bỏ qua cài vào /Applications) ==="
    exit 0
fi

# 5. Install to /Applications/XDrive.app for system-wide access & Dock
echo "=== Installing to /Applications/XDrive.app ==="
rm -rf /Applications/XDrive.app
cp -R "$APP_BUNDLE" /Applications/XDrive.app

echo "=== Build & Install Complete: /Applications/XDrive.app ==="

