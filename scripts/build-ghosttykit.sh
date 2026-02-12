#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHOSTTY_DIR="$ROOT_DIR/vendor/ghostty"
LIBXEV_DIR="$ROOT_DIR/vendor/libxev"
OUT_FRAMEWORK="$GHOSTTY_DIR/macos/GhosttyKit.xcframework"
APP_FRAMEWORK_DIR="$ROOT_DIR/Hoshi/Frameworks"
APP_FRAMEWORK_LINK="$APP_FRAMEWORK_DIR/GhosttyKit.xcframework"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command not found: $1" >&2
    exit 1
  fi
}

need_cmd git
need_cmd zig
need_cmd rg

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
(
  cd "$GHOSTTY_DIR"
  zig build -Demit-xcframework -Doptimize=ReleaseFast
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

mkdir -p "$APP_FRAMEWORK_DIR"
rm -rf "$APP_FRAMEWORK_LINK"
ln -s ../../vendor/ghostty/macos/GhosttyKit.xcframework "$APP_FRAMEWORK_LINK"

echo "==> GhosttyKit ready"
echo "framework: $APP_FRAMEWORK_LINK -> ../../vendor/ghostty/macos/GhosttyKit.xcframework"
