#!/usr/bin/env bash
# Captures raw App Store screenshots from the Simulator against the Docker
# screenshot host. Output: .shots/raw/<device>/<name>.png (native size).
#
#   scripts/screenshots/host.sh up            # once: build + start the hosts
#   scripts/screenshots/capture.sh            # iPhone 6.3" (all scenes)
#   scripts/screenshots/capture.sh ipad-13    # iPad 13"
#   SKIP_BUILD=1 scripts/screenshots/capture.sh iphone-6.3 agents
#
# Scenes are grouped in runs that share one app launch: `agents`, `terminal`,
# and the opt-in `codex` (real Codex on this Mac; see codex.sh).
# Coordinates are in points for the given device; see notes inline. The
# accessibility tree goes stale while the terminal is on screen, so most taps
# inside a session use coordinates rather than labels.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

device=${1:-iphone-6.3}
runs=${2:-agents terminal}
udid=$(device_udid "$device")
raw="$SHOTS_OUT/raw/$device"
mkdir -p "$raw"
trigger="$SHOTS_ROOT/scripts/screenshots/trigger.sh"

# Per-device layout (points). iPhone 17 Pro is 402x874; iPad Pro 13" 1032x1376.
case $device in
iphone-*)
  MENU=(362 86)          # terminal "…" (Terminal tools)
  MENU_UPLOAD=(280 96); MENU_FILES=(280 137); MENU_VOICE=(259 189)
  BACK=(24 86); SESSION_BTN=(95 86)
  REPLY_LOCK=(347 740)   # Reply on the Lock Screen Live Activity
  ALLOW_LA=(289 710)     # "Always Allow" on the first-run Live Activity prompt
  REPLY_FIELD=(150 805); REPLY_SEND=(366 807)
  VOICE_GRABBER=(201 430); VOICE_DRAFT=(201 534); SHEET_CANCEL=(58 111)
  FILES_HOSHI=(120 420)   # second row in ~ (backups, hoshi, logs, …)
  JOY=(200 420); SELECT=(52 336)
  ;;
ipad-*)
  # Portrait split view. Header buttons move when the sidebar hides, so the
  # ones used with it hidden are listed separately.
  KB_DISMISS=(1002 1332)  # software keyboard's hide key (bottom right)
  SIDEBAR_TOGGLE=(328 54); SIDEBAR_SHOW=(32 54)
  SIDEBAR_DEVBOX=(142 283) # Servers > devbox, below one active session
  REPLY_FIELD=(495 980)    # reply composer in the centred agent sheet
  OUTSIDE_SHEET=(900 1250)
  FILES_FULL=(848 110); FILES_DONE=(272 390)
  runs=${2:-ipad}
  ;;
esac

at() { tap_xy "$udid" "$1" "$2" "${3:-0.6}"; }
hold_at() { # x y seconds: touch down, wait, capture callback runs while held
  axe touch -x "$1" -y "$2" --down --udid "$udid" >/dev/null
}
release_at() { axe touch -x "$1" -y "$2" --up --udid "$udid" >/dev/null; }
tmux_window() { docker exec -u fcoury shots-devbox tmux select-window -t "$1"; sleep 1.5; }
lock_and_wake() {
  axe button lock --udid "$udid" >/dev/null; sleep 1.2
  axe button lock --udid "$udid" >/dev/null; sleep 2
}
# Dismiss a system permission alert if one is up (first run on a simulator).
allow_if_prompted() {
  local label
  for label in "Always Allow" "Allow"; do
    if [ -n "$(find_frame "$udid" "$label" 2>/dev/null)" ]; then
      tap_label "$udid" "$label"; sleep 1.5; return 0
    fi
  done
}

open_picker_scrolled_to_tmux() {
  open_picker "$udid" "fcoury@devbox.localhost"
  axe swipe --start-x 200 --start-y 650 --end-x 200 --end-y 250 --duration 0.5 --udid "$udid" >/dev/null
  sleep 1.5
}

run_agents() {
  log "run: agents (Herdr agent, Live Activity, reply)"
  SHOTS_HOLD=1 fresh_launch "$udid"
  open_picker "$udid" "fcoury@devbox.localhost"
  tap_prefix "$udid" "Builder, hoshi"; sleep 7
  shot "$udid" "$raw/agent-working.png"

  # Writer finishes, reviewer blocks: Hoshi sees both happen live.
  "$trigger" finish; sleep 4
  "$trigger" block; sleep 6
  lock_and_wake
  # First run per simulator only: "Allow Live Activities from Hoshi?" sits under
  # the card and isn't in the accessibility tree. Once allowed, the same spot is
  # the card itself (which would open the app), so remember that it's done.
  local la_marker="$SHOTS_OUT/.live-activities-allowed-$udid"
  if [ ! -f "$la_marker" ]; then
    at "${ALLOW_LA[@]}" 0.3; sleep 2
    touch "$la_marker"
  fi
  shot "$udid" "$raw/lock-live-activity.png"

  # Reply opens the app on the agent; Mosh resyncs after the background trip.
  at "${REPLY_LOCK[@]}"; sleep 8
  shot "$udid" "$raw/reply-sheet.png"
  # The terminal keyboard stays down while the reply sheet is up, so one tap
  # focuses the composer.
  at "${REPLY_FIELD[@]}" 0.8; sleep 1.2
  axe type "Yes, run the migration" --udid "$udid" >/dev/null; sleep 1
  shot "$udid" "$raw/reply-typed.png"
  at "${REPLY_SEND[@]}"; sleep 5
  shot "$udid" "$raw/reply-sent.png"
}

# Opt-in (needs `codex.sh setup`): real Codex on this Mac in the Builder pane.
# Codex answers in about 20 s, so one frame catches it working, one done.
run_codex() {
  log "run: codex (real Codex over SSH in a Herdr pane)"
  SHOTS_HOLD=0 fresh_launch "$udid"
  "$SHOTS_ROOT/scripts/screenshots/codex.sh" swap
  open_picker "$udid" "fcoury@devbox.localhost"
  tap_prefix "$udid" "Codex"; sleep 4
  shot "$udid" "$raw/codex-working.png"
  sleep "${CODEX_WAIT:-30}"
  shot "$udid" "$raw/codex.png"
}

run_terminal() {
  log "run: terminal (picker, tmux, joystick, selection, voice, sftp, sessions)"
  SHOTS_HOLD=0 fresh_launch "$udid"
  open_picker "$udid" "fcoury@devbox.localhost"
  sleep 3   # let all three agents settle: working, needs input, done
  tap_label "$udid" "Refresh sessions" 0.5 || true; sleep 3
  shot "$udid" "$raw/picker.png"

  axe swipe --start-x 200 --start-y 650 --end-x 200 --end-y 250 --duration 0.5 --udid "$udid" >/dev/null
  sleep 1.5
  tap_prefix "$udid" "hoshi, 3 windows"; sleep 6
  shot "$udid" "$raw/tmux-git.png"

  # Joystick over vim: hold still, nudge right under the 36pt threshold.
  tmux_window hoshi:3
  hold_at "${JOY[@]}"; sleep 0.8
  axe touch -x $((JOY[0] + 22)) -y "${JOY[1]}" --down --udid "$udid" >/dev/null 2>&1 || true
  sleep 0.4; shot "$udid" "$raw/joystick.png"
  release_at $((JOY[0] + 22)) "${JOY[1]}"; sleep 1

  # Selection: long-press a commit hash and release in place.
  tmux_window hoshi:1
  hold_at "${SELECT[@]}"; sleep 0.6; release_at "${SELECT[@]}"; sleep 1.2
  shot "$udid" "$raw/selection.png"
  at 200 650; sleep 0.8   # clear the selection

  # Voice composer with an editable draft.
  at "${MENU[@]}"; sleep 1.2; at "${MENU_VOICE[@]}" 0.4; sleep 2
  if find_frame "$udid" "Allow Speech Recognition" >/dev/null 2>&1 && [ -n "$(find_frame "$udid" "Allow Speech Recognition")" ]; then
    tap_label "$udid" "Allow Speech Recognition"; sleep 2; allow_if_prompted
  fi
  axe swipe --start-x "${VOICE_GRABBER[0]}" --start-y "${VOICE_GRABBER[1]}" --end-x "${VOICE_GRABBER[0]}" --end-y 90 --duration 0.5 --udid "$udid" >/dev/null
  sleep 1.5; at "${VOICE_DRAFT[@]}" 0.4; sleep 1
  axe type "Refactor the session store to use actors, then add tests for restore." --udid "$udid" >/dev/null
  sleep 1; shot "$udid" "$raw/voice.png"
  at "${SHEET_CANCEL[@]}" 0.5; sleep 1.5

  # SFTP: home folder, then the upload sheet.
  at "${MENU[@]}"; sleep 1.2; at "${MENU_FILES[@]}" 0.5; sleep 3
  shot "$udid" "$raw/sftp-home.png"
  at "${FILES_HOSHI[@]}" 1; sleep 3
  shot "$udid" "$raw/sftp-repo.png"
  at "${SHEET_CANCEL[@]}" 0.5; sleep 1.5
  at "${MENU[@]}"; sleep 1.2; at "${MENU_UPLOAD[@]}" 0.5; sleep 3
  shot "$udid" "$raw/upload.png"
  at "${SHEET_CANCEL[@]}" 0.5; sleep 1.5

  # More sessions, then the Active Sessions sheet.
  at "${BACK[@]}"; sleep 2
  open_picker "$udid" "fcoury@gpu.localhost"
  tap_prefix "$udid" "train, 1 window"; sleep 6
  at "${BACK[@]}"; sleep 2
  open_picker "$udid" "fcoury@api.localhost"
  tap_prefix "$udid" "logs, 1 window"; sleep 6
  shot "$udid" "$raw/prod-api-logs.png"
  at "${SESSION_BTN[@]}"; sleep 2
  shot "$udid" "$raw/sessions-sheet.png"
  tap_label "$udid" "Done" 0.5; sleep 1.5   # close the sheet, then leave
  at "${BACK[@]}"; sleep 2.5
  shot "$udid" "$raw/server-list.png"
}

run_ipad() {
  log "run: ipad (split view agent, reply, vim, sftp, sessions)"
  SHOTS_HOLD=0 fresh_launch "$udid"
  open_picker "$udid" "fcoury@devbox.localhost"
  tap_prefix "$udid" "Builder, hoshi"; sleep 7
  # Most iPad users type on a hardware keyboard: hide the software one, then
  # have the agent repaint at the final size.
  at "${KB_DISMISS[@]}" 0.5; sleep 2
  docker exec -u fcoury shots-devbox pkill -WINCH -f "agent.py working" || true
  sleep 1.5
  shot "$udid" "$raw/split-agent.png"

  tap_label "$udid" "Herdr agents" 0.5; sleep 2.5
  tap_prefix "$udid" "Reviewer"; sleep 3
  at "${REPLY_FIELD[@]}" 0.8; sleep 1.2
  axe type "Yes, run the migration" --udid "$udid" >/dev/null; sleep 1
  shot "$udid" "$raw/reply.png"
  at "${OUTSIDE_SHEET[@]}" 0.5; sleep 1.5

  # A second session from the sidebar: tmux, vim window.
  at "${SIDEBAR_DEVBOX[@]}"
  wait_for "$udid" "Open Raw Shell" 40 >/dev/null; sleep 1
  axe swipe --start-x 516 --start-y 900 --end-x 516 --end-y 500 --duration 0.5 --udid "$udid" >/dev/null
  sleep 1.5
  tap_prefix "$udid" "hoshi, 3 windows"; sleep 6
  tmux_window hoshi:3; sleep 1
  shot "$udid" "$raw/sessions.png"
  at "${SIDEBAR_TOGGLE[@]}" 0.5; sleep 3
  shot "$udid" "$raw/vim.png"

  at "${FILES_FULL[@]}" 0.5; sleep 4
  shot "$udid" "$raw/sftp.png"
  at "${FILES_DONE[@]}" 0.8; sleep 1.5
  at "${SIDEBAR_SHOW[@]}" 0.5; sleep 2
}

[ "${SKIP_BUILD:-0}" = 1 ] || build_app
prepare_sim "$udid"
for r in $runs; do "run_$r"; done
log "done: $raw"
