#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if ! command -v zig >/dev/null 2>&1 && command -v brew >/dev/null 2>&1; then
  ZIG_PREFIX="$(brew --prefix zig@0.15 2>/dev/null || true)"
  if [[ -n "$ZIG_PREFIX" && -x "$ZIG_PREFIX/bin/zig" ]]; then
    export PATH="$ZIG_PREFIX/bin:$PATH"
  fi
fi

for command in git zig rg xcodegen xcodebuild; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "error: required command not found: $command" >&2
    echo "install the prerequisites documented in README.md and try again" >&2
    exit 1
  fi
done

if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  echo "error: Xcode's first-launch components are not installed" >&2
  echo "run: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer" >&2
  echo "then: sudo xcodebuild -runFirstLaunch" >&2
  exit 1
fi

ZIG_VERSION="$(zig version)"
if [[ "$ZIG_VERSION" != 0.15.* ]]; then
  echo "error: Ghostty requires Zig 0.15.x, but found Zig $ZIG_VERSION" >&2
  echo "run: brew install zig@0.15" >&2
  exit 1
fi

echo "==> Initializing Ghostty submodules"
git -C "$ROOT_DIR" submodule update --init --recursive -- vendor/ghostty vendor/libxev

"$ROOT_DIR/scripts/build-ghosttykit.sh"

echo "==> Generating Hoshi.xcodeproj"
xcodegen --spec "$ROOT_DIR/Hoshi/project.yml" --project "$ROOT_DIR/Hoshi"

echo "==> Hoshi is ready to build"
