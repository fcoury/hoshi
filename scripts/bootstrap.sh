#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${HOSHI_GITHUB_REPO:-fcoury/hoshi}"

usage() {
  cat <<'USAGE'
usage: scripts/bootstrap.sh [--prebuilt]

  --prebuilt  Download a GhosttyKit.xcframework built by this repository's
              GhosttyKit workflow instead of building it locally. You don't
              need Zig or the Metal toolchain. Use this unless you're changing
              vendor/ghostty, vendor/libxev, or the GhosttyKit build scripts.
USAGE
}

PREBUILT=0
for arg in "$@"; do
  case "$arg" in
    --prebuilt) PREBUILT=1 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "error: unknown option: $arg" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if ! command -v zig >/dev/null 2>&1 && command -v brew >/dev/null 2>&1; then
  ZIG_PREFIX="$(brew --prefix zig@0.15 2>/dev/null || true)"
  if [[ -n "$ZIG_PREFIX" && -x "$ZIG_PREFIX/bin/zig" ]]; then
    export PATH="$ZIG_PREFIX/bin:$PATH"
  fi
fi

required_commands=(git rg xcodegen xcodebuild)
if [[ "$PREBUILT" == 1 ]]; then
  required_commands+=(curl shasum ditto)
else
  required_commands+=(zig)
fi

for command in "${required_commands[@]}"; do
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

if [[ "$PREBUILT" == 0 ]]; then
  ZIG_VERSION="$(zig version)"
  if [[ "$ZIG_VERSION" != 0.15.* ]]; then
    echo "error: Ghostty requires Zig 0.15.x, but found Zig $ZIG_VERSION" >&2
    echo "run: brew install zig@0.15" >&2
    echo "or skip the local build with: scripts/bootstrap.sh --prebuilt" >&2
    exit 1
  fi
fi

echo "==> Initializing Ghostty submodules"
git -C "$ROOT_DIR" submodule update --init --recursive -- vendor/ghostty vendor/libxev

if [[ "$PREBUILT" == 1 ]]; then
  TAG="$("$ROOT_DIR/scripts/ghosttykit-key.sh")"
  FRAMEWORK="$ROOT_DIR/vendor/ghostty/macos/GhosttyKit.xcframework"
  MARKER="$FRAMEWORK/.hoshi-prebuilt-tag"

  if [[ -f "$MARKER" && "$(cat "$MARKER")" == "$TAG" ]]; then
    echo "==> Prebuilt GhosttyKit $TAG is already installed"
  else
    echo "==> Downloading prebuilt GhosttyKit $TAG"
    BASE_URL="https://github.com/$REPO/releases/download/$TAG"
    DOWNLOAD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hoshi-ghosttykit.XXXXXXXX")"
    trap 'rm -rf "$DOWNLOAD_DIR"' EXIT

    if ! curl -fL --progress-bar -o "$DOWNLOAD_DIR/GhosttyKit.xcframework.zip" \
      "$BASE_URL/GhosttyKit.xcframework.zip" \
      || ! curl -fsSL -o "$DOWNLOAD_DIR/GhosttyKit.xcframework.zip.sha256" \
      "$BASE_URL/GhosttyKit.xcframework.zip.sha256"; then
      echo "error: no prebuilt GhosttyKit is published for $TAG" >&2
      echo "This happens when vendor/ghostty, vendor/libxev, or the GhosttyKit build" >&2
      echo "scripts differ from a commit the GhosttyKit workflow has built." >&2
      echo "Build it locally instead: scripts/bootstrap.sh (needs Zig 0.15 and the Metal toolchain)" >&2
      exit 1
    fi

    echo "==> Verifying checksum"
    (cd "$DOWNLOAD_DIR" && shasum -a 256 -c GhosttyKit.xcframework.zip.sha256)

    rm -rf "$FRAMEWORK"
    mkdir -p "$(dirname "$FRAMEWORK")"
    ditto -x -k "$DOWNLOAD_DIR/GhosttyKit.xcframework.zip" "$(dirname "$FRAMEWORK")"
    echo "$TAG" > "$MARKER"
  fi

  HOSHI_GHOSTTYKIT_PREBUILT=1 "$ROOT_DIR/scripts/build-ghosttykit.sh"
else
  "$ROOT_DIR/scripts/build-ghosttykit.sh"
fi

echo "==> Generating Hoshi.xcodeproj"
xcodegen --spec "$ROOT_DIR/Hoshi/project.yml" --project "$ROOT_DIR/Hoshi"

echo "==> Hoshi is ready to build"
