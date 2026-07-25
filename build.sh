#!/bin/bash
# build.sh — 编译 + 打包 XDVPN.app
# 用法：
#   ./build.sh          # 只构建 .app
#   ./build.sh release  # 构建 + 产出 XDVPN-<version>.zip（给 GitHub Release 用）
set -euo pipefail

cd "$(dirname "$0")"

MODE="${1:-app}"
CA_FILE="/etc/ssl/cert.pem"

if [[ ! -r "$CA_FILE" ]]; then
    echo "error: macOS CA bundle not readable: $CA_FILE" >&2
    exit 1
fi

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
if [[ -f Resources/THIRD_PARTY_NOTICES.md ]]; then
    cp Resources/THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
fi

echo "==> vendoring openconnect"
scripts/vendor-openconnect.sh "$APP"

echo "==> vendoring ocproxy"
scripts/vendor-ocproxy.sh "$APP"

echo "==> signing bundled openconnect + ocproxy"
find "$APP/Contents/Resources/openconnect" -type f \( -perm +111 -o -name '*.dylib' \) -exec codesign --force --sign - {} \;

# ad-hoc 签名（Icon.png 已就位，签名覆盖整个包）
codesign --force --deep --sign - "$APP"

echo "==> verifying bundled openconnect"
"$APP/Contents/Resources/openconnect/bin/openconnect" --cafile="$CA_FILE" --version | head -n 1

echo "==> verifying clean-system portability"
while IFS= read -r -d '' runtime_file; do
    file "$runtime_file" | grep -q 'Mach-O' || continue
    if otool -L "$runtime_file" | tail -n +2 | awk '{print $1}' \
        | grep -Eq '^(/opt/homebrew|/usr/local)(/|$)'; then
        echo "error: Homebrew dependency remains in $runtime_file" >&2
        otool -L "$runtime_file" >&2
        exit 1
    fi
    if otool -l "$runtime_file" | awk '/cmd LC_RPATH/{getline; getline; print $2}' \
        | grep -Eq '^(/opt/homebrew|/usr/local)(/|$)'; then
        echo "error: Homebrew rpath remains in $runtime_file" >&2
        exit 1
    fi
done < <(find "$APP/Contents" -type f -print0)

env -i HOME=/tmp PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR=/tmp \
    sandbox-exec -p '(version 1) (allow default) (deny file-read* (subpath "/opt/homebrew")) (deny file-read* (subpath "/usr/local"))' \
    "$APP/Contents/Resources/openconnect/bin/openconnect" \
    --cafile="$CA_FILE" --version | head -n 1
codesign --verify --deep --strict "$APP"

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
