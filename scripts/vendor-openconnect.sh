#!/bin/bash
# Copy openconnect and its non-system dylib dependencies into XDVPN.app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?usage: vendor-openconnect.sh build/XDVPN.app}"
LOCK="$ROOT/Vendor/openconnect.lock"

if [[ ! -d "$APP/Contents/Resources" ]]; then
    echo "error: app resources directory not found: $APP/Contents/Resources" >&2
    exit 1
fi

allowed_minor="$(awk -F= '/^allowed_minor=/{print $2}' "$LOCK")"
if [[ -z "$allowed_minor" ]]; then
    echo "error: missing allowed_minor in $LOCK" >&2
    exit 1
fi

find_openconnect() {
    if [[ -n "${XDVPN_OPENCONNECT_PATH:-}" && -x "${XDVPN_OPENCONNECT_PATH:-}" ]]; then
        printf '%s\n' "$XDVPN_OPENCONNECT_PATH"
        return
    fi
    for path in /opt/homebrew/bin/openconnect /usr/local/bin/openconnect; do
        if [[ -x "$path" ]]; then
            printf '%s\n' "$path"
            return
        fi
    done
    if command -v openconnect >/dev/null 2>&1; then
        command -v openconnect
        return
    fi
    return 1
}

source_bin="$(find_openconnect || true)"
if [[ -z "$source_bin" ]]; then
    echo "error: openconnect not found; install it with Homebrew before building" >&2
    exit 1
fi
source_bin="$(realpath "$source_bin")"

version_line="$(LC_ALL=C "$source_bin" --version 2>&1 | head -n 1)"
case "$version_line" in
  "OpenConnect version v${allowed_minor}"|"OpenConnect version v${allowed_minor}."*|"OpenConnect version v${allowed_minor}-"*) ;;
  *)
    echo "error: unsupported openconnect version: $version_line" >&2
    echo "       allowed minor is $allowed_minor.x; update Vendor/openconnect.lock after compatibility testing" >&2
    exit 1
    ;;
esac

VENDOR_DIR="$APP/Contents/Resources/openconnect"
BIN_DIR="$VENDOR_DIR/bin"
LIB_DIR="$VENDOR_DIR/lib"
QUEUE="$VENDOR_DIR/.queue"
SEEN="$VENDOR_DIR/.seen"

rm -rf "$VENDOR_DIR"
mkdir -p "$BIN_DIR" "$LIB_DIR"
: > "$QUEUE"
: > "$SEEN"

brew_prefixes=()
for brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "$brew" ]]; then
        brew_prefixes+=("$("$brew" --prefix)")
    fi
done
brew_prefixes+=("/opt/homebrew" "/usr/local")

is_system_dep() {
    case "$1" in
      /usr/lib/*|/System/Library/*) return 0 ;;
      *) return 1 ;;
    esac
}

deps_for() {
    otool -L "$1" | tail -n +2 | awk '{print $1}'
}

resolve_dep() {
    local dep="$1"
    local base
    case "$dep" in
      /*)
        [[ -f "$dep" ]] && realpath "$dep"
        ;;
      @rpath/*|@loader_path/*|@executable_path/*)
        base="$(basename "$dep")"
        for prefix in "${brew_prefixes[@]}"; do
            for candidate in "$prefix/lib/$base" "$prefix"/opt/*/lib/"$base" "$prefix"/Cellar/*/*/lib/"$base"; do
                if [[ -f "$candidate" ]]; then
                    realpath "$candidate"
                    return
                fi
            done
        done
        ;;
    esac
}

enqueue_library() {
    local path="$1"
    local real
    real="$(realpath "$path")"
    if grep -Fxq "$real" "$SEEN"; then
        return
    fi
    echo "$real" >> "$SEEN"
    echo "$real" >> "$QUEUE"
}

copy_file() {
    local src="$1"
    local dst="$2"
    cp -L "$src" "$dst"
    chmod u+rw,go+r "$dst"
}

rewrite_loads() {
    local file="$1"
    local mode="$2"
    local dep resolved base new_path

    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        is_system_dep "$dep" && continue
        resolved="$(resolve_dep "$dep" || true)"
        if [[ -z "$resolved" ]]; then
            echo "error: unable to resolve dependency $dep for $file" >&2
            exit 1
        fi
        base="$(basename "$resolved")"
        if [[ "$mode" == "bin" ]]; then
            new_path="@loader_path/../lib/$base"
        else
            new_path="@loader_path/$base"
        fi
        install_name_tool -change "$dep" "$new_path" "$file" 2>/dev/null || true
    done < <(deps_for "$file")

    if [[ "$mode" == "lib" ]]; then
        install_name_tool -id "@loader_path/$(basename "$file")" "$file" 2>/dev/null || true
    fi
}

copy_file "$source_bin" "$BIN_DIR/openconnect"
chmod 0755 "$BIN_DIR/openconnect"

while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    is_system_dep "$dep" && continue
    resolved="$(resolve_dep "$dep" || true)"
    if [[ -z "$resolved" ]]; then
        echo "error: unable to resolve dependency $dep for $source_bin" >&2
        exit 1
    fi
    enqueue_library "$resolved"
done < <(deps_for "$source_bin")

while [[ -s "$QUEUE" ]]; do
    dep="$(head -n 1 "$QUEUE")"
    tail -n +2 "$QUEUE" > "$QUEUE.tmp"
    mv "$QUEUE.tmp" "$QUEUE"

    dst="$LIB_DIR/$(basename "$dep")"
    if [[ ! -f "$dst" ]]; then
        copy_file "$dep" "$dst"
    fi

    while IFS= read -r child; do
        [[ -z "$child" ]] && continue
        is_system_dep "$child" && continue
        resolved="$(resolve_dep "$child" || true)"
        if [[ -z "$resolved" ]]; then
            echo "error: unable to resolve dependency $child for $dep" >&2
            exit 1
        fi
        enqueue_library "$resolved"
    done < <(deps_for "$dep")
done

rewrite_loads "$BIN_DIR/openconnect" bin
for lib in "$LIB_DIR"/*.dylib; do
    [[ -e "$lib" ]] || continue
    rewrite_loads "$lib" lib
done

rm -f "$QUEUE" "$SEEN"
cat > "$VENDOR_DIR/VERSION" <<EOF
allowed_minor=$allowed_minor
version=$version_line
EOF

chmod -R u+rwX,go+rX,go-w "$VENDOR_DIR"

echo "==> vendored $version_line from $source_bin"
