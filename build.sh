#!/bin/bash
# build.sh — 编译 + 打包 XDVPN.app
# 用法：
#   ./build.sh          # 只构建 .app
#   ./build.sh release  # 构建 + 产出 XDVPN-<version>.zip（给 GitHub Release 用）
set -euo pipefail

cd "$(dirname "$0")"

MODE="${1:-app}"

# 从 Info.plist 读版本号
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)

echo "==> swift build (v$VERSION)"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)"
APP="build/XDVPN.app"

echo "==> packaging $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/XDVPN" "$APP/Contents/MacOS/XDVPN"
cp "$BIN_PATH/xdvpn-dns-proxy" "$APP/Contents/MacOS/xdvpn-dns-proxy"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Icon.png "$APP/Contents/Resources/Icon.png"

# ad-hoc 签名（Icon.png 已就位，签名覆盖整个包）
codesign --force --deep --sign - "$APP"

echo ""
echo "✅ 构建完成：$APP"

if [[ "$MODE" == "release" ]]; then
    ZIP="build/XDVPN-v${VERSION}.zip"
    rm -f "$ZIP"
    # ditto 保留扩展属性和 ad-hoc 签名，比 zip 命令更可靠
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
    echo ""
    echo "📦 Release zip：$ZIP ($(du -h "$ZIP" | cut -f1))"
fi

echo ""
echo "运行： open $APP"
