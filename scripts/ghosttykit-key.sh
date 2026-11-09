#!/usr/bin/env bash
# Prints the release tag that identifies a prebuilt GhosttyKit.xcframework.
#
# The tag changes whenever the vendored Ghostty or libxev commit, or the
# scripts that build the framework, change. The GhosttyKit workflow publishes
# a release under this tag, and `bootstrap.sh --prebuilt` downloads it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ghostty_sha="$(git -C "$ROOT_DIR" rev-parse HEAD:vendor/ghostty)"
libxev_sha="$(git -C "$ROOT_DIR" rev-parse HEAD:vendor/libxev)"
scripts_hash="$(
  cat "$ROOT_DIR/scripts/build-ghosttykit.sh" "$ROOT_DIR/scripts/ghostty-libtool.sh" \
    | shasum -a 256 | cut -c1-16
)"

echo "ghosttykit-${ghostty_sha:0:12}-${libxev_sha:0:12}-${scripts_hash}"
