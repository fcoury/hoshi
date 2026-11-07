#!/usr/bin/env bash
# Forced command for the devbox key (see codex.sh): Codex in this repo,
# read-only, never asking for approval. Only the prompt comes from the client.
# The title names the app (Hoshi switches to the Coding Agent keys on "Codex")
# and neither the title nor the status line shows account limits.
#   codex-remote.sh CODEX_BIN [PROMPT]
set -euo pipefail
codex=$1; prompt=${2:-}
cd "$(dirname "$0")/../.."
args=(-s read-only -a never
  -c 'tui.terminal_title=["app-name","thread-title"]'
  -c 'tui.status_line=["model-with-reasoning","git-branch"]')
if [ -n "$prompt" ]; then exec "$codex" "${args[@]}" "$prompt"; else exec "$codex" "${args[@]}"; fi
