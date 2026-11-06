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
event() { echo "$1 $(perl -e "printf '%.3f', $(now) - $T0") ${2:-} ${3:-}" >>"$EVENTS"; }
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
  rm -f "$EVENTS"
  log "recorded ${out#$SHOTS_ROOT/}/$1.mov"
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
