#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE="$BUILD_DIR/XDrive.app"
PKG_OUTPUT="$BUILD_DIR/XDrive-AppStore.pkg"

echo "=== Đóng gói XDrive cho Apple App Store Connect (vn.xox.xdrive) ==="

# 1. Tìm chứng chỉ Apple Distribution & Installer
APP_SIGN_IDENTITY="$(security find-identity -p codesigning -v | grep -E 'Apple Distribution:' | head -n 1 | awk -F'\"' '{print $2}' || true)"
INSTALLER_SIGN_IDENTITY="$(security find-identity -v | grep -E '3rd Party Mac Developer Installer:' | head -n 1 | awk -F'\"' '{print $2}' || true)"

if [ -z "$APP_SIGN_IDENTITY" ]; then
    echo "❌ Lỗi: Không tìm thấy chứng chỉ 'Apple Distribution'."
    exit 1
fi
echo "🔒 Chứng chỉ ký App: $APP_SIGN_IDENTITY"
echo "📦 Chứng chỉ ký Installer: $INSTALLER_SIGN_IDENTITY"

cd "$PROJECT_DIR"
swift build -c release --product XDrive
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_DIR/XDrive" "$APP_BUNDLE/Contents/MacOS/XDrive"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# 2. Biên dịch Assets.car & AppIcon.icns bằng actool
echo "🎨 Biên dịch Asset Catalog (Assets.car)..."
xcrun actool "$PROJECT_DIR/Resources/Assets.xcassets" \
    --compile "$APP_BUNDLE/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist /tmp/actool-partial.plist

# 3. Nhúng Provisioning Profile
PROFILE_SRC="$PROJECT_DIR/Resources/XDrive_AppStore.provisionprofile"
if [ ! -f "$PROFILE_SRC" ]; then
    PROFILE_SRC="$(find ~/Downloads -maxdepth 1 -name "*XDrive*.provisionprofile" 2>/dev/null | head -n 1 || true)"
fi
if [ -n "$PROFILE_SRC" ] && [ -f "$PROFILE_SRC" ]; then
    echo "📄 Nhúng Provisioning Profile: $PROFILE_SRC"
    cp "$PROFILE_SRC" "$APP_BUNDLE/Contents/embedded.provisionprofile"
else
    echo "❌ Lỗi: Không tìm thấy file provisionprofile!"
    exit 1
fi

# 4. Xóa toàn bộ quarantine attribute (khắc phục lỗi 91109)
echo "🧹 Xóa bỏ thuộc tính com.apple.quarantine..."
xattr -rc "$APP_BUNDLE"

# 5. Ký số App Bundle với App Sandbox
echo "=== Ký số XDrive.app với Entitlements ==="
codesign --force --options runtime --sign "$APP_SIGN_IDENTITY" --entitlements "$PROJECT_DIR/Resources/XDrive.entitlements" "$APP_BUNDLE/Contents/MacOS/XDrive"
codesign --force --options runtime --sign "$APP_SIGN_IDENTITY" --entitlements "$PROJECT_DIR/Resources/XDrive.entitlements" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

# 6. Đóng gói .pkg
echo "=== Tạo gói cài đặt .pkg (productbuild) ==="
rm -f "$PKG_OUTPUT"
productbuild --component "$APP_BUNDLE" /Applications --sign "$INSTALLER_SIGN_IDENTITY" "$PKG_OUTPUT"

echo "=== ĐÃ HOÀN TẤT BẢN BUILD MỚI: $PKG_OUTPUT ==="
ls -lh "$PKG_OUTPUT"
