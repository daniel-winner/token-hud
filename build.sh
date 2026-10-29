#!/bin/bash
# 构建 TokenHUD.app（原生 macOS 置顶浮窗）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/.build"
APP="$ROOT/dist/TokenHUD.app"

echo "==> 编译"
mkdir -p "$BUILD"
# 编译 Sources/TokenHUD 下的全部 swift 文件（新增文件自动纳入，无需手工维护清单）
swiftc -O -parse-as-library \
  -o "$BUILD/TokenHUD" \
  "$ROOT"/Sources/TokenHUD/*.swift \
  -framework AppKit -framework SwiftUI

echo "==> 组装 .app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/TokenHUD" "$APP/Contents/MacOS/TokenHUD"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>TokenHUD</string>
    <key>CFBundleDisplayName</key><string>Token 监控</string>
    <key>CFBundleIdentifier</key><string>cn.workbuddy.tokenhud</string>
    <key>CFBundleExecutable</key><string>TokenHUD</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

# 临时签名，避免 Gatekeeper 拦截本地构建产物
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "==> 完成：$APP"
