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

if [[ "$MODE" == "release" ]]; then
    NOTES_FILE="RELEASE_NOTES.md"
    if [[ ! -f "$NOTES_FILE" ]] \
        || ! grep -Fq "# XDVPN v${VERSION}" "$NOTES_FILE" \
        || ! awk '
            /^## 更新了什么[[:space:]]*$/ { in_updates = 1; next }
            in_updates && /^## / { exit }
            in_updates && NF { found = 1; exit }
            END { exit !found }
        ' "$NOTES_FILE"; then
        echo "error: $NOTES_FILE must describe XDVPN v${VERSION} and include non-empty '## 更新了什么' content" >&2
        exit 1
    fi
fi

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
cp RELEASE_NOTES.md "$APP/Contents/Resources/RELEASE_NOTES.md"
if [[ -f Resources/THIRD_PARTY_NOTICES.md ]]; then
    cp Resources/THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
fi

ALLOWED_MINOR="$(awk -F= '/^allowed_minor=/{print $2}' Vendor/openconnect.lock)"

if [[ -n "${XDVPN_PREBUILT_RUNTIME_DIR:-}" ]]; then
    # 原样内置 scripts/fetch-prebuilt-runtime.sh 取回的运行时（正式发布走这条路）。
    echo "==> bundling prebuilt openconnect runtime from $XDVPN_PREBUILT_RUNTIME_DIR"
    for required in VERSION bin/openconnect bin/ocproxy lib; do
        if [[ ! -e "$XDVPN_PREBUILT_RUNTIME_DIR/$required" ]]; then
            echo "error: prebuilt runtime is missing $required" >&2
            exit 1
        fi
    done
    ditto "$XDVPN_PREBUILT_RUNTIME_DIR" "$APP/Contents/Resources/openconnect"
else
    echo "==> vendoring openconnect"
    scripts/vendor-openconnect.sh "$APP"

    echo "==> vendoring ocproxy"
    scripts/vendor-ocproxy.sh "$APP"
fi

echo "==> signing bundled openconnect + ocproxy"
find "$APP/Contents/Resources/openconnect" -type f \( -perm +111 -o -name '*.dylib' \) -exec codesign --force --sign - {} \;

# ad-hoc 签名（Icon.png 已就位，签名覆盖整个包）
codesign --force --deep --sign - "$APP"

echo "==> verifying bundled openconnect"
OC_VERSION_LINE="$("$APP/Contents/Resources/openconnect/bin/openconnect" --cafile="$CA_FILE" --version | head -n 1)"
echo "$OC_VERSION_LINE"
if ! printf '%s\n' "$OC_VERSION_LINE" | grep -qE "v${ALLOWED_MINOR}(\$|[.-])"; then
    echo "error: bundled openconnect is not ${ALLOWED_MINOR}.x (see Vendor/openconnect.lock)" >&2
    exit 1
fi

# 包里每个二进制要求的最低系统版本都不能高于 App 声明支持的版本。
# 换构建机或换依赖来源时，这一项最容易悄悄变高。
echo "==> verifying minimum macOS version"
MIN_OS="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Resources/Info.plist)"
while IFS= read -r -d '' runtime_file; do
    file "$runtime_file" | grep -q 'Mach-O' || continue
    required_os="$(otool -l "$runtime_file" | awk '
        $1 == "cmd" { cmd = $2 }
        cmd == "LC_BUILD_VERSION" && $1 == "minos" { print $2 }
        cmd == "LC_VERSION_MIN_MACOSX" && $1 == "version" { print $2 }
    ')"
    if [[ -z "$required_os" ]]; then
        echo "error: cannot read minimum macOS version of $runtime_file" >&2
        exit 1
    fi
    while IFS= read -r version; do
        if ! awk -v need="$version" -v have="$MIN_OS" 'BEGIN {
            split(need, n, "."); split(have, h, ".")
            for (i = 1; i <= 3; i++) {
                if (n[i] + 0 < h[i] + 0) exit 0
                if (n[i] + 0 > h[i] + 0) exit 1
            }
            exit 0
        }'; then
            echo "error: $runtime_file requires macOS $version, but the app declares $MIN_OS" >&2
            exit 1
        fi
    done <<< "$required_os"
done < <(find "$APP/Contents" -type f -print0)
echo "all binaries run on macOS $MIN_OS"

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
