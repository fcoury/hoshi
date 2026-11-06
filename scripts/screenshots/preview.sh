#!/usr/bin/env bash
# Records the App Preview takes from the Simulator against the screenshot host.
# Output: .shots/preview/<device>/<take>.mov plus <take>.json with the moments
# (marks) and taps that compose-preview.mjs cuts and decorates.
#
#   scripts/screenshots/preview.sh                 # iPhone 6.3", both takes
#   SKIP_BUILD=1 scripts/screenshots/preview.sh iphone-6.3 agents
#
# Takes: `agents` (picker, live agent, Lock Screen reply) and `terminal`
# (tmux, vim, joystick). The terminal font is JetBrains Mono for the video.
#
# Website film takes (opt-in, one per wish):
#   hack      raw shell: vim README.md, retitle it, :wq, git commit, git log
#   mosh      gpu-box training log; the network drops ~20 s and comes back
#   keysets   shell -> vim -> less -> codex, the key bar follows the title
#   custom    add a `git st` key, then (seeded first in the bar) tap it
#   themes    terminal, Settings: theme + font, back to the terminal
#   codex     real Codex in the Herdr Builder pane (needs codex.sh setup)
#   SKIP_BUILD=1 scripts/screenshots/preview.sh iphone-6.3 "hack mosh keysets custom themes codex"
set -euo pipefail
source "$(dirname "$0")/lib.sh"

device=${1:-iphone-6.3}
takes=${2:-agents terminal}
udid=$(device_udid "$device")
out="$SHOTS_OUT/preview/$device"
trigger="$SHOTS_ROOT/scripts/screenshots/trigger.sh"
mkdir -p "$out"
export SHOTS_FONT=${SHOTS_FONT:-JetBrainsMono Nerd Font Mono}

# iPhone 17 Pro points (see capture.sh).
REPLY_LOCK=(347 740); REPLY_FIELD=(150 805); REPLY_SEND=(366 807)
JOY=(200 420)

now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

# Every tap and mark lands in the take's event log, in seconds from the
# first recorded frame.
T0=0; EVENTS=""
event() { # taps before the first record_start (setup) aren't logged
  [ -n "$EVENTS" ] || return 0
  echo "$1 $(perl -e "printf '%.3f', $(now) - $T0") ${2:-} ${3:-}" >>"$EVENTS"
}
mark() { event mark "$1"; }
tap_xy() { # same as lib.sh; axe takes ~2s to start, so log when it returns
  sleep "${4:-0.4}"
  axe tap -x "$2" -y "$3" --udid "$1" >/dev/null
  event tap "$2" "$3"
}
touch_down() { axe touch -x "$1" -y "$2" --down --udid "$udid" >/dev/null 2>&1 || true; event down "$1" "$2"; }
touch_up() { axe touch -x "$1" -y "$2" --up --udid "$udid" >/dev/null; event up "$1" "$2"; }
type_slowly() { # word by word, so typing reads on camera
  local word first=1
  for word in $1; do
    [ $first = 1 ] && first=0 || word=" $word"
    axe type "$word" --udid "$udid" >/dev/null; sleep 0.18
  done
}

REC_PID=""
record_start() { # $1 take name
  local log="$out/$1.rec.log"
  rm -f "$out/$1.mov"; : >"$log"
  EVENTS="$out/$1.events"; : >"$EVENTS"
  xcrun simctl io "$udid" recordVideo --codec=h264 --force "$out/$1.mov" 2>"$log" &
  REC_PID=$!
  for _ in $(seq 100); do grep -q "Recording started" "$log" && break; sleep 0.05; done
  T0=$(now)
  log "recording $1"
}
record_stop() { # $1 take name
  kill -INT "$REC_PID"; wait "$REC_PID" 2>/dev/null || true
  python3 - "$EVENTS" "$out/$1.json" <<'PY'
import json, sys
marks, touches = {}, []
for line in open(sys.argv[1]):
    kind, t, *rest = line.split()
    if kind == "mark":
        marks[rest[0]] = float(t)
    else:
        touches.append({"kind": kind, "t": float(t), "x": float(rest[0]), "y": float(rest[1])})
json.dump({"marks": marks, "touches": touches}, open(sys.argv[2], "w"), indent=1)
PY
  rm -f "$EVENTS"; EVENTS=""
  log "recorded ${out#$SHOTS_ROOT/}/$1.mov"
}

# Film helpers -------------------------------------------------------------

type_cmd() { type_slowly "$1"; sleep 0.25; axe key 40 --udid "$udid" >/dev/null; }
quiet_cmd() { axe type "$1" --udid "$udid" >/dev/null; axe key 40 --udid "$udid" >/dev/null; }
raw_shell() { # devbox, no tmux: the title follows the foreground command
  open_picker "$udid" "fcoury@devbox.localhost"
  tap_label "$udid" "Open Raw Shell"; sleep 4
  quiet_cmd "cd ${1:-~/hoshi} && clear"; sleep 1.5
}
# Network loss on gpu-box, with the phone's signal bars off to match.
net_off() {
  docker exec shots-gpu-box tc qdisc add dev eth0 root netem loss 100%
  xcrun simctl status_bar "$udid" override --wifiMode failed --wifiBars 0 --cellularMode notSupported >/dev/null
}
net_on() {
  docker exec shots-gpu-box tc qdisc del dev eth0 root 2>/dev/null || true
  xcrun simctl status_bar "$udid" override --wifiMode active --wifiBars 3 --cellularMode active \
    --cellularBars 4 --dataNetwork wifi >/dev/null
}

# iPhone 17 Pro points, Settings sheet.
SETTINGS=(38 84); SHEET_BACK=(38 100); SHEET_DONE=(349 100); BACK=(24 86)
FONT_ROW=(200 250); THEME_ROW=(200 364); KEYSETS_ROW=(200 719)
THEME_TOKYO=(200 503); THEME_CATPPUCCIN=(200 561); FONT_VICTOR=(200 666)
SHELL_SET=(200 704); EDIT_DONE=(349 110); KEY_LABEL=(200 331); KEY_SEND=(200 440)
KEYBAR_FIRST=(34 851)

take_hack() {
  SHOTS_HOLD=0 fresh_launch "$udid"
  raw_shell
  record_start hack
  sleep 0.8; mark shell
  type_cmd "vim README.md"; sleep 1.8; mark vim
  type_cmd ":1s/$/, the terminal I wished for/"; sleep 1.8; mark edit
  type_cmd ":wq"; sleep 0.6
  axe key-combo --modifiers 224 --key 15 --udid "$udid" >/dev/null; sleep 0.6   # ^L
  type_cmd "git commit -qam 'docs: the terminal I wished for'"; sleep 1
  type_cmd "git log --oneline -3"; sleep 1.2; mark commit; sleep 2
  mark end
  record_stop hack
}

take_mosh() {
  SHOTS_HOLD=0 fresh_launch "$udid"
  open_picker "$udid" "fcoury@gpu.localhost"
  record_start mosh
  sleep 0.6; mark picker
  tap_prefix "$udid" "train"; sleep 3; mark stream; sleep 3
  trap net_on EXIT
  net_off; mark drop; sleep 21
  net_on; trap - EXIT; mark back; sleep 6
  mark end
  record_stop mosh
}

take_keysets() {
  SHOTS_HOLD=0 fresh_launch "$udid"
  raw_shell "~/hoshi/Hoshi/Hoshi/Services/Mosh"
  record_start keysets
  sleep 0.8; mark shell; sleep 1
  type_cmd "vim MoshStateSync.swift"; sleep 1.5; mark vim; sleep 1.5
  type_cmd ":q"; sleep 0.6
  type_cmd "less ~/logs/api.log"; sleep 1.2; mark less; sleep 1.5
  axe type q --udid "$udid" >/dev/null; sleep 0.6
  type_cmd "codex"; sleep 4; mark codex; sleep 2
  mark end
  record_stop keysets
}

take_custom() {
  # Part 1: built-in key sets; add the key in Settings.
  SHOTS_HOLD=0 fresh_launch "$udid"
  wait_for "$udid" "fcoury@devbox.localhost" 30 >/dev/null; sleep 1
  record_start custom-add
  sleep 0.6; mark list
  tap_xy "$udid" "${SETTINGS[@]}"; sleep 1.5
  tap_xy "$udid" "${KEYSETS_ROW[@]}"; sleep 1.3
  tap_xy "$udid" "${SHELL_SET[@]}"; sleep 1.5; mark editor
  tap_label "$udid" "Custom"; sleep 1.2; mark form
  tap_xy "$udid" "${KEY_LABEL[@]}"; sleep 0.4; type_slowly "git st"
  tap_xy "$udid" "${KEY_SEND[@]}"; sleep 0.4; type_slowly "git space status enter"; sleep 1.2; mark sends
  tap_label "$udid" "Add"; sleep 1.2
  for _ in 1 2; do # scroll the key order to its end, where the new key lands
    axe swipe --start-x 360 --start-y 267 --end-x 20 --end-y 267 --duration 0.3 --udid "$udid" >/dev/null; sleep 0.5
  done
  sleep 0.6; mark added; sleep 1.2
  mark end
  record_stop custom-add
  # Part 2: the same key, moved to the front (seeded), in a real shell.
  SHOTS_KEY_SETS="$SHOTS_ROOT/scripts/screenshots/seeds/key-sets-git-st.json" SHOTS_HOLD=0 fresh_launch "$udid"
  raw_shell
  record_start custom-use
  sleep 0.8; mark shell; sleep 0.6
  tap_xy "$udid" "${KEYBAR_FIRST[@]}" 0.2; sleep 1.8; mark status; sleep 1.5
  mark end
  record_stop custom-use
}

take_themes() {
  SHOTS_HOLD=0 fresh_launch "$udid"
  open_picker "$udid" "fcoury@devbox.localhost"; sleep 1
  axe swipe --start-x 200 --start-y 650 --end-x 200 --end-y 250 --duration 0.5 --udid "$udid" >/dev/null
  sleep 1.5
  tap_prefix "$udid" "hoshi, 3 windows"; sleep 3
  docker exec -u fcoury shots-devbox tmux select-window -t hoshi:3; sleep 2
  record_start themes
  sleep 0.8; mark before; sleep 1.2
  tap_xy "$udid" "${BACK[@]}"; sleep 1.5
  tap_xy "$udid" "${SETTINGS[@]}"; sleep 1.3; mark settings
  tap_xy "$udid" "${THEME_ROW[@]}"; sleep 1.2; mark themes
  tap_xy "$udid" "${THEME_TOKYO[@]}"; sleep 1
  tap_xy "$udid" "${THEME_CATPPUCCIN[@]}"; sleep 1
  tap_xy "$udid" "${SHEET_BACK[@]}"; sleep 1
  tap_xy "$udid" "${FONT_ROW[@]}"; sleep 1.2; mark fonts
  tap_xy "$udid" "${FONT_VICTOR[@]}"; sleep 1
  tap_xy "$udid" "${SHEET_BACK[@]}"; sleep 0.8
  tap_xy "$udid" "${SHEET_DONE[@]}"; sleep 1.2
  tap_prefix "$udid" "devbox, " ; sleep 2.5; mark after; sleep 2
  mark end
  record_stop themes
}

take_codex() {
  SHOTS_HOLD=0 fresh_launch "$udid"
  CODEX_TITLE=${CODEX_TITLE:-"Find where key sets are picked"} "$SHOTS_ROOT/scripts/screenshots/codex.sh" swap \
    "${CODEX_PROMPT:-Where does Hoshi decide which key set to show? Three short bullets, read only.}"
  open_picker "$udid" "fcoury@devbox.localhost"
  record_start codex
  sleep 0.8; mark picker
  tap_prefix "$udid" "Codex"; sleep 1; mark codex; sleep 30
  mark end
  record_stop codex
}

take_agents() {
  SHOTS_HOLD=2 fresh_launch "$udid"
  wait_for "$udid" "fcoury@devbox.localhost" 30 >/dev/null; sleep 1
  record_start agents
  sleep 0.8; mark list; sleep 1
  tap_prefix "$udid" "fcoury@devbox.localhost"
  wait_for "$udid" "Open Raw Shell" 40 >/dev/null; mark picker; sleep 2
  tap_prefix "$udid" "Builder, hoshi"; sleep 3
  "$trigger" start; mark builder; sleep 6
  # Writer finishes, reviewer asks for approval; phone goes to the pocket.
  "$trigger" finish; sleep 1.5; "$trigger" block; sleep 2.5
  axe button lock --udid "$udid" >/dev/null; sleep 1.2
  axe button lock --udid "$udid" >/dev/null; sleep 0.6; mark lock; sleep 2.6
  tap_xy "$udid" "${REPLY_LOCK[@]}" 0.2; mark open; sleep 4.5
  mark reply
  tap_xy "$udid" "${REPLY_FIELD[@]}" 0.3; sleep 0.8
  type_slowly "Yes, run the migration"; sleep 0.7
  tap_xy "$udid" "${REPLY_SEND[@]}" 0.2; mark sent; sleep 4.5
  mark end
  record_stop agents
}

take_terminal() {
  SHOTS_HOLD=0 fresh_launch "$udid"
  open_picker "$udid" "fcoury@devbox.localhost"; sleep 2
  axe swipe --start-x 200 --start-y 650 --end-x 200 --end-y 250 --duration 0.5 --udid "$udid" >/dev/null
  sleep 1.5
  record_start terminal
  sleep 0.6; mark picker
  tap_prefix "$udid" "hoshi, 3 windows" ; sleep 3.5; mark tmux; sleep 1.5
  docker exec -u fcoury shots-devbox tmux select-window -t hoshi:3; sleep 1.2; mark vim; sleep 0.6
  # Joystick: hold still until it appears, push right, then down.
  touch_down "${JOY[@]}"; sleep 0.8
  touch_down $((JOY[0] + 60)) "${JOY[1]}"; sleep 1.2
  touch_down "${JOY[0]}" $((JOY[1] + 60)); sleep 1.0
  touch_up "${JOY[0]}" $((JOY[1] + 60)); sleep 1.2
  mark end
  record_stop terminal
}

[ "${SKIP_BUILD:-0}" = 1 ] || build_app
prepare_sim "$udid"
for t in $takes; do "take_$t"; done
log "done: $out"
