#!/usr/bin/env bash
# Real Codex for the agent screenshot and the film. Hoshi connects to devbox
# over Mosh and attaches to Herdr; the Builder pane runs ssh back to this Mac,
# where a forced command starts Codex in this repo, read-only.
#
#   scripts/screenshots/codex.sh setup          key in devbox, forced-command line in ~/.ssh/authorized_keys
#   scripts/screenshots/codex.sh swap [PROMPT]  after host.sh restart: Builder pane -> Codex on this Mac
#   scripts/screenshots/codex.sh remove         undo setup
#
# Needs Remote Login (System Settings > General > Sharing) and a signed-in
# `codex` on PATH. The devbox key can only run `codex -s read-only -a never`
# in this repo, with the prompt the client sends: no shell, no forwarding.
# Herdr recognises agents by process name, so the ssh client runs from a copy
# named `codex`, and the pane lists as a real Codex agent.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

MARK=hoshi-shots-codex
C=shots-devbox
KEYS="$HOME/.ssh/authorized_keys"
PROMPT_DEFAULT="Explain in a few short bullets how the Mosh client notices that mosh-server went silent. Read only, don't change any files."

case ${1:?setup|swap|remove} in
setup)
  codex_bin=$(command -v codex) || { echo "codex isn't on PATH" >&2; exit 1; }
  docker exec -u fcoury "$C" bash -c "mkdir -p ~/.ssh ~/.local/shim && chmod 700 ~/.ssh
    [ -f ~/.ssh/hoshi_codex ] || ssh-keygen -q -t ed25519 -N '' -C $MARK -f ~/.ssh/hoshi_codex
    [ -x ~/.local/shim/codex ] || cp /usr/bin/ssh ~/.local/shim/codex"
  pub=$(docker exec -u fcoury "$C" cat /home/fcoury/.ssh/hoshi_codex.pub)
  mkdir -p "$HOME/.ssh"; touch "$KEYS"; chmod 600 "$KEYS"
  [ -f "$KEYS.bak-$MARK" ] || cp "$KEYS" "$KEYS.bak-$MARK"
  # cd/&&/exec and "$VAR" read the same in bash, zsh and fish.
  line="command=\"cd '$SHOTS_ROOT' && exec '$codex_bin' -s read-only -a never \\\"\$SSH_ORIGINAL_COMMAND\\\"\",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-user-rc $pub $MARK"
  { grep -v -e "$MARK" "$KEYS" || true; printf '%s\n' "$line"; } > "$KEYS.tmp"
  cat "$KEYS.tmp" > "$KEYS"; rm "$KEYS.tmp"
  log "authorized $MARK for codex in $SHOTS_ROOT (backup: $KEYS.bak-$MARK)"
  ;;
swap)
  prompt=${2:-$PROMPT_DEFAULT}
  docker exec -u fcoury -e PROMPT="$prompt" -e MAC_USER="$(id -un)" "$C" bash -lc '
    for _ in $(seq 60); do
      p=$(herdr agent list 2>/dev/null | python3 -c "import json,sys
try: print([a[\"pane_id\"] for a in json.load(sys.stdin)[\"result\"][\"agents\"] if a[\"agent\"]==\"builder\"][0])
except Exception: pass")
      [ -n "$p" ] && break; sleep 0.5
    done
    [ -n "$p" ] || { echo "no builder pane on devbox" >&2; exit 1; }
    pkill -f "[a]gent.py working" || true; sleep 1.5
    herdr pane run "$p" "clear; ~/.local/shim/codex -tt -q -o StrictHostKeyChecking=accept-new -i ~/.ssh/hoshi_codex $MAC_USER@host.docker.internal $(printf %q "$PROMPT")" >/dev/null'
  log "builder pane now runs Codex on this Mac"
  ;;
remove)
  if [ -f "$KEYS" ]; then
    { grep -v -e "$MARK" "$KEYS" || true; } > "$KEYS.tmp"; cat "$KEYS.tmp" > "$KEYS"; rm "$KEYS.tmp"
  fi
  docker exec -u fcoury "$C" rm -f /home/fcoury/.ssh/hoshi_codex /home/fcoury/.ssh/hoshi_codex.pub /home/fcoury/.local/shim/codex 2>/dev/null || true
  log "removed $MARK"
  ;;
*) echo "usage: $0 setup|swap [PROMPT]|remove" >&2; exit 2 ;;
esac
