#!/bin/bash
# 取回已发布安装包里的 OpenConnect 运行时，供 build.sh 原样内置。
#
# 用法： fetch-prebuilt-runtime.sh <输出目录>
#        XDVPN_PREBUILT_RUNTIME_DIR=<输出目录> ./build.sh
#
# 为什么不在打包时用 Homebrew 现装：Homebrew 的二进制把最低系统版本定为构建机的
# 系统版本，而且不再为旧系统提供全部依赖。现装会让 App 悄悄只能在更新的系统上运行，
# 并把加密库换成没有跟这一版 XDVPN 一起验证过的版本。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/Vendor/prebuilt-runtime.lock"
DEST="${1:?usage: fetch-prebuilt-runtime.sh <output-dir>}"

url="$(awk -F= '/^url=/{print substr($0, 5)}' "$LOCK")"
sha256="$(awk -F= '/^sha256=/{print $2}' "$LOCK")"
if [[ -z "$url" || -z "$sha256" ]]; then
    echo "error: $LOCK must define url and sha256" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> fetching $url"
curl --fail --silent --show-error --location --retry 3 --output "$WORK/app.zip" "$url"

actual="$(shasum -a 256 "$WORK/app.zip" | awk '{print $1}')"
if [[ "$actual" != "$sha256" ]]; then
    echo "error: checksum mismatch for $url" >&2
    echo "       expected $sha256" >&2
    echo "       actual   $actual" >&2
    exit 1
fi

ditto -x -k "$WORK/app.zip" "$WORK/extracted"
RUNTIME="$WORK/extracted/XDVPN.app/Contents/Resources/openconnect"
if [[ ! -x "$RUNTIME/bin/openconnect" ]]; then
    echo "error: no OpenConnect runtime inside $url" >&2
    exit 1
fi

rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
ditto "$RUNTIME" "$DEST"
echo "==> prebuilt runtime ready: $DEST ($(sed -n 's/^version=//p' "$DEST/VERSION"))"
