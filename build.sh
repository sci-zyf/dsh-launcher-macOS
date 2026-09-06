#!/bin/bash
# 构建 DSH Launcher.app。源码在本目录,产物固定放 ~/Applications/DSH Launcher.app。
# 用法: bash build.sh   (可在任意位置运行,源位置由本脚本自动定位)

set -e

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/DSH Launcher.app"
BIN_NAME="DSHLauncher"

echo "=== 编译 Swift ==="
swiftc -O "$SRC_DIR/main.swift" -o /tmp/"$BIN_NAME"

echo "=== 组装 .app ==="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp /tmp/"$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"
cp "$SRC_DIR/launcher.sh" "$APP/Contents/Resources/launcher.sh"
chmod +x "$APP/Contents/MacOS/$BIN_NAME" "$APP/Contents/Resources/launcher.sh"
if [ -f "$SRC_DIR/icon.icns" ]; then
    cp "$SRC_DIR/icon.icns" "$APP/Contents/Resources/icon.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>DSH Launcher</string>
	<key>CFBundleDisplayName</key>
	<string>DSH Launcher</string>
	<key>CFBundleIdentifier</key>
	<string>local.dsh.launcher</string>
	<key>CFBundleVersion</key>
	<string>1.0</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleExecutable</key>
	<string>DSHLauncher</string>
	<key>CFBundleIconFile</key>
	<string>icon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>LSMinimumSystemVersion</key>
	<string>12.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

rm -f /tmp/"$BIN_NAME"
echo "=== 完成: $APP ==="
