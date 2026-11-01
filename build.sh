#!/bin/bash
# 编译并安装「批量解压.app」，安装后注册到 LaunchServices（出现在「打开方式」里）
set -euo pipefail
cd "$(dirname "$0")"

APP_DIR="build/批量解压.app"
INSTALL_TARGET="/Applications"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "❌ 未找到 swiftc，请先安装 Xcode Command Line Tools：xcode-select --install"
    exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"

echo "==> 编译中…"
swiftc -O -target arm64-apple-macos11.0 -o "$APP_DIR/Contents/MacOS/BatchUnzip" main.swift -framework AppKit

cp Info.plist "$APP_DIR/Contents/Info.plist"

echo "==> 生成图标…"
mkdir -p "$APP_DIR/Contents/Resources"
rm -rf build/AppIcon.iconset
swift make_icon.swift build/AppIcon.iconset >/dev/null
iconutil -c icns build/AppIcon.iconset -o "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "==> 签名…"
codesign --force -s - "$APP_DIR"

# /Applications 不可写时退回 ~/Applications
if [ ! -w "/Applications" ]; then
    INSTALL_TARGET="$HOME/Applications"
    mkdir -p "$INSTALL_TARGET"
fi

echo "==> 安装到 ${INSTALL_TARGET}…"
# 应用正在运行时先退出，避免替换二进制后出现异常状态
pkill -x BatchUnzip 2>/dev/null && sleep 1
rm -rf "$INSTALL_TARGET/批量解压.app"
cp -R "$APP_DIR" "$INSTALL_TARGET/"

echo "==> 注册到 LaunchServices…"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$INSTALL_TARGET/批量解压.app"

echo "✅ 已安装：$INSTALL_TARGET/批量解压.app"
echo "使用方法：Finder 选中压缩包 → 右键 → 打开方式 → 其他… → 批量解压"
