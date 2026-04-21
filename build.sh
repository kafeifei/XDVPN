#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

echo "==> swift build"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)"
APP="build/XDVPN.app"

echo "==> packaging $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/XDVPN" "$APP/Contents/MacOS/XDVPN"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# ad-hoc 签名，绕过 Gatekeeper "App 已损坏" 提示
codesign --force --deep --sign - "$APP"

echo ""
echo "✅ 构建完成：$APP"
echo ""
echo "运行： open $APP"
echo "首次启动若被 Gatekeeper 拦截：右键 → 打开，或系统设置 → 隐私与安全性里放行。"
