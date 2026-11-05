#!/usr/bin/env bash
# Builds the deterministic tmux and Herdr state for this container's role.
# Run as the login user:  docker exec -u fcoury shots-devbox /opt/shots/setup.sh
# Idempotent: tears down previous sessions first.
#
# Agent labels default to neutral role names; override with SHOTS_AGENTS,
# e.g. SHOTS_AGENTS="claude codex claude".
set -euo pipefail
cd "$HOME"
role=$(cat /etc/shots-role 2>/dev/null || echo devbox)
read -r A1 A2 A3 <<<"${SHOTS_AGENTS:-builder reviewer writer}"
# SHOTS_HOLD=1: reviewer waits for /tmp/shots/block, writer for /tmp/shots/finish
# (see scripts/screenshots/trigger.sh), so Hoshi sees those changes happen.
rm -rf /tmp/shots && mkdir -p /tmp/shots
if [ "${SHOTS_HOLD:-0}" = 1 ]; then HB="--hold /tmp/shots/block"; HF="--hold /tmp/shots/finish"; else HB=""; HF=""; fi

tmux kill-server 2>/dev/null || true
tmux -L herdr kill-server 2>/dev/null || true
pkill -f "herdr" 2>/dev/null || true
pkill -f "/opt/shots/(agent.py|train.sh|logs.sh)" 2>/dev/null || true
sleep 1   # herdr writes session state on shutdown; clean up after it exits
rm -rf "$HOME/.config/herdr/sessions"

# One tmux session per name; the first window runs $2 if given.
session() {
  local name=$1 cmd=${2:-} dir=${3:-$HOME} win=${4:-}
  tmux new-session -d -s "$name" -c "$dir" -x 120 -y 40 ${win:+-n "$win"}
  [ -n "$cmd" ] && tmux send-keys -t "$name" "$cmd" Enter
  return 0
}

case "$role" in
devbox)
  session hoshi "clear; git --no-pager log --no-merges --color=always --format='%C(yellow)%h%C(reset) %<(23,trunc)%s' -16; echo; git status -sb" "$HOME/hoshi" git
  tmux new-window -t hoshi -n tests -c "$HOME/hoshi"
  tmux new-window -t hoshi -n vim -c "$HOME/hoshi" "vim -c '/func serverIsSilent' -c 'normal! zt' -c 'nohlsearch' Hoshi/Hoshi/Services/Mosh/MoshStateSync.swift"
  tmux select-window -t hoshi:1
  session api "clear; printf '\\e[38;5;114m▲\\e[0m api listening on :8080\\n'; tail -f /dev/null" "$HOME"
  session infra "clear; df -h / | tail -1; uptime" "$HOME"
  session notes "vim -c 'set ft=markdown' ~/notes.md" "$HOME"
  mkdir -p ~/logs ~/screenshots ~/backups
  cp ~/hoshi/assets/screenshots/6.9/*.png ~/screenshots/ 2>/dev/null || true
  printf 'mosh-server 1.4.0 started on udp 60200\nclient roamed 10.0.0.12 -> 172.20.4.9\n' > ~/logs/mosh.log
  seq 1 400 | sed 's/^/request /' > ~/logs/api.log
  printf '#!/bin/sh\nset -e\ngit pull --ff-only\nmake release\n' > ~/deploy.sh && chmod +x ~/deploy.sh
  head -c 2400000 /dev/urandom > ~/backups/sessions-2026-11-05.tar.gz
  cat > ~/notes.md <<'EOF'
# Launch checklist

- [x] 1.2.0 submitted for review
- [x] README rewrite (MIT)
- [ ] New App Store screenshots
- [ ] Website: open-source angle
- [ ] Show HN post
EOF

  # Herdr runs headless: a client in a private tmux socket keeps the server
  # alive without showing up in Hoshi's tmux picker.
  tmux -L herdr new-session -d -x 160 -y 48 -c "$HOME/hoshi" "herdr"
  for _ in $(seq 30); do herdr workspace list >/dev/null 2>&1 && break; sleep 0.3; done
  H="herdr"
  ws1=$($H workspace list | python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["workspaces"][0]["workspace_id"])')
  $H workspace rename "$ws1" hoshi >/dev/null 2>&1 || true
  p1=$($H pane list | python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["panes"][0]["pane_id"])')
  $H pane run "$p1" "/opt/shots/agent.py working --label $A1" >/dev/null
  p2=$($H pane split "$p1" --direction down --no-focus | python3 -c 'import json,sys;d=json.load(sys.stdin)["result"];print(d.get("pane_id") or d["pane"]["pane_id"])')
  $H pane run "$p2" "/opt/shots/agent.py approval --label $A2 $HB" >/dev/null
  $H workspace create --cwd "$HOME/hoshi" --label site --no-focus >/dev/null
  ws3=$($H workspace list | python3 -c 'import json,sys;w=json.load(sys.stdin)["result"]["workspaces"];print([x for x in w if x["label"]=="site"][0]["workspace_id"])')
  p3=$($H pane list | python3 -c "import json,sys;p=json.load(sys.stdin)['result']['panes'];print([x for x in p if x['workspace_id']=='$ws3'][0]['pane_id'])")
  $H pane run "$p3" "/opt/shots/agent.py done --label $A3 $HF" >/dev/null
  ;;
gpu-box)
  session train "clear; /opt/shots/train.sh" "$HOME"
  session monitor "htop" "$HOME"
  ;;
prod-api)
  session logs "clear; /opt/shots/logs.sh" "$HOME"
  session shell "" "$HOME"
  ;;
esac

sleep 2
tmux ls
herdr agent list 2>/dev/null | python3 -c 'import json,sys
try:
  for a in json.load(sys.stdin)["result"]["agents"]: print(a["agent"], a["agent_status"], a.get("title",""))
except Exception: pass' || true
