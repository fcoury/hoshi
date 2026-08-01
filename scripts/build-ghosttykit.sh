#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHOSTTY_DIR="$ROOT_DIR/vendor/ghostty"
LIBXEV_DIR="$ROOT_DIR/vendor/libxev"
OUT_FRAMEWORK="$GHOSTTY_DIR/macos/GhosttyKit.xcframework"
APP_FRAMEWORK_DIR="$ROOT_DIR/Hoshi/Frameworks"
APP_FRAMEWORK_LINK="$APP_FRAMEWORK_DIR/GhosttyKit.xcframework"
BUILD_JOBS="${HOSHI_GHOSTTY_BUILD_JOBS:-6}"
ZIG_LOCAL_CACHE_DIR="${HOSHI_ZIG_LOCAL_CACHE_DIR:-$GHOSTTY_DIR/.zig-cache/hoshi-aligned-archives}"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if ! command -v zig >/dev/null 2>&1 && command -v brew >/dev/null 2>&1; then
  ZIG_PREFIX="$(brew --prefix zig@0.15 2>/dev/null || true)"
  if [[ -n "$ZIG_PREFIX" && -x "$ZIG_PREFIX/bin/zig" ]]; then
    export PATH="$ZIG_PREFIX/bin:$PATH"
  fi
fi

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command not found: $1" >&2
    exit 1
  fi
}

need_cmd git
need_cmd zig
need_cmd rg

ZIG_VERSION="$(zig version)"
if [[ "$ZIG_VERSION" != 0.15.* ]]; then
  echo "error: Ghostty requires Zig 0.15.x, but found Zig $ZIG_VERSION" >&2
  echo "run: brew install zig@0.15" >&2
  exit 1
fi

if ! xcrun --sdk iphoneos metal -v >/dev/null 2>&1; then
  METAL_TOOLCHAIN_IDENTIFIER="$(
    xcodebuild -showComponent MetalToolchain -json 2>/dev/null \
      | /usr/bin/plutil -extract toolchainIdentifier raw - 2>/dev/null || true
  )"
  if [[ -n "$METAL_TOOLCHAIN_IDENTIFIER" ]]; then
    export TOOLCHAINS="$METAL_TOOLCHAIN_IDENTIFIER"
  else
    echo "error: Xcode's Metal Toolchain is not installed" >&2
    echo "run: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
  fi
fi

if [[ ! -e "$GHOSTTY_DIR/.git" ]]; then
  echo "error: missing submodule at $GHOSTTY_DIR" >&2
  echo "run: git submodule update --init --recursive vendor/ghostty vendor/libxev" >&2
  exit 1
fi

if [[ ! -e "$LIBXEV_DIR/.git" ]]; then
  echo "error: missing submodule at $LIBXEV_DIR" >&2
  echo "run: git submodule update --init --recursive vendor/ghostty vendor/libxev" >&2
  exit 1
fi

echo "==> Building GhosttyKit.xcframework"
LIBTOOL_WRAPPER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hoshi-ghostty-tools.XXXXXXXX")"
trap 'rm -rf "$LIBTOOL_WRAPPER_DIR"' EXIT
export HOSHI_REAL_LIBTOOL="$(xcrun --find libtool)"
ln -s "$ROOT_DIR/scripts/ghostty-libtool.sh" "$LIBTOOL_WRAPPER_DIR/libtool"
export PATH="$LIBTOOL_WRAPPER_DIR:$PATH"

(
  cd "$GHOSTTY_DIR"
  zig build \
    --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
    -j"$BUILD_JOBS" \
    -Dapp-runtime=none \
    -Demit-xcframework \
    -Demit-macos-app=false \
    -Doptimize=ReleaseFast
)

if [[ ! -d "$OUT_FRAMEWORK" ]]; then
  echo "error: expected framework output not found at $OUT_FRAMEWORK" >&2
  exit 1
fi

echo "==> Verifying required iOS APIs are present in ghostty.h"
HEADER="$GHOSTTY_DIR/include/ghostty.h"
required_symbols=(
  "ghostty_surface_write_pty_output"
  "ghostty_surface_set_pty_input_callback"
  "ghostty_surface_prepend_scrollback"
  "ghostty_surface_scrollback_offset"
  "ghostty_surface_is_alternate_screen"
  "ghostty_surface_set_power_mode"
)

for symbol in "${required_symbols[@]}"; do
  if ! rg -q "$symbol" "$HEADER"; then
    echo "error: missing required symbol in $HEADER: $symbol" >&2
    exit 1
  fi
done

echo "==> Verifying required Ghostty APIs are exported by each iOS library"
required_exports=(
  "_ghostty_init"
  "_ghostty_app_new"
  "_ghostty_surface_new"
  "_ghostty_surface_write_pty_output"
  "_ghostty_surface_set_pty_input_callback"
)

for slice in ios-arm64 ios-arm64-simulator; do
  library="$OUT_FRAMEWORK/$slice/libghostty-fat.a"
  if [[ ! -f "$library" ]]; then
    echo "error: missing Ghostty library for required slice: $slice" >&2
    exit 1
  fi

  exported_symbols="$(nm -gU "$library")"
  for symbol in "${required_exports[@]}"; do
    if [[ "$exported_symbols" != *"$symbol"* ]]; then
      echo "error: missing required export in $library: $symbol" >&2
      exit 1
    fi
  done
done

mkdir -p "$APP_FRAMEWORK_DIR"
rm -rf "$APP_FRAMEWORK_LINK"
ln -s ../../vendor/ghostty/macos/GhosttyKit.xcframework "$APP_FRAMEWORK_LINK"

echo "==> GhosttyKit ready"
echo "framework: $APP_FRAMEWORK_LINK -> ../../vendor/ghostty/macos/GhosttyKit.xcframework"
