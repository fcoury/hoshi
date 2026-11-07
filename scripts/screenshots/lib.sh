#!/usr/bin/env bash
# Shared helpers for the screenshot pipeline. Source it; don't run it.
# Requires: Xcode simulators, AXe (brew install cameroncooke/axe/axe), Docker.
set -euo pipefail

SHOTS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SHOTS_OUT=${SHOTS_OUT:-$SHOTS_ROOT/.shots}
SHOTS_DERIVED=${SHOTS_DERIVED:-$SHOTS_ROOT/.shots/DerivedData}
BUNDLE_ID=app.gethoshi.ios
APP_PATH="$SHOTS_DERIVED/Build/Products/Debug-iphonesimulator/Hoshi.app"

# device key -> simulator name and native capture size
device_name() {
  case $1 in
  iphone-6.3) echo "iPhone 17 Pro" ;;        # 1206x2622 (required set)
  iphone-6.9) echo "iPhone 17 Pro Max" ;;    # 1320x2868
  ipad-13)    echo "iPad Pro 13-inch (M5)" ;; # 2064x2752
  *) echo "unknown device $1" >&2; return 1 ;;
  esac
}

device_udid() {
  local name; name=$(device_name "$1")
  xcrun simctl list devices available | grep -F "    $name (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'
}

log() { printf '\033[38;5;75m▸\033[0m %s\n' "$*" >&2; }

build_app() {
  log "building Hoshi (Debug, simulator)"
  (cd "$SHOTS_ROOT/Hoshi" && xcodegen generate -q >/dev/null &&
    xcodebuild -project Hoshi.xcodeproj -scheme Hoshi -configuration Debug \
      -destination 'generic/platform=iOS Simulator' -derivedDataPath "$SHOTS_DERIVED" \
      -quiet build)
}

# Boot, set dark mode and a clean 9:41 status bar, install the app.
prepare_sim() {
  local udid=$1
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  # US English region, so dates, units and dictation language read naturally.
  # The system only picks it up after a reboot.
  if [ "$(xcrun simctl spawn "$udid" defaults read -g AppleLocale 2>/dev/null)" != en_US ] ||
     xcrun simctl spawn "$udid" defaults read -g AppleKeyboards 2>/dev/null | grep -v -e en_US -e emoji -e '[()]' | grep -q .; then
    xcrun simctl spawn "$udid" defaults write -g AppleLocale en_US
    xcrun simctl spawn "$udid" defaults write -g AppleLanguages -array en-US
    xcrun simctl spawn "$udid" defaults write -g AppleKeyboards -array "en_US@sw=QWERTY;hw=Automatic" emoji@sw=Emoji
    xcrun simctl shutdown "$udid"; xcrun simctl boot "$udid"
    xcrun simctl bootstatus "$udid" -b >/dev/null
  fi
  xcrun simctl ui "$udid" appearance dark
  # No red spell-check squiggles or autocorrect in typed text.
  for k in KeyboardCheckSpelling KeyboardAutocorrection KeyboardPrediction KeyboardAutocapitalization; do
    xcrun simctl spawn "$udid" defaults write com.apple.Preferences "$k" -bool NO
  done
  xcrun simctl status_bar "$udid" override --time "9:41" --dataNetwork wifi --wifiMode active \
    --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 \
    --operatorName ""
  xcrun simctl install "$udid" "$APP_PATH"
  xcrun simctl privacy "$udid" grant microphone "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl privacy "$udid" grant speech-recognition "$BUNDLE_ID" 2>/dev/null || true
}

# App settings live in UserDefaults; write them before launch.
app_defaults() {
  local udid=$1
  local d=(xcrun simctl spawn "$udid" defaults)
  "${d[@]}" delete "$BUNDLE_ID" app.gethoshi.active-session-descriptors 2>/dev/null || true
  "${d[@]}" delete "$BUNDLE_ID" app.gethoshi.agent-events 2>/dev/null || true
  "${d[@]}" write "$BUNDLE_ID" app.gethoshi.agent-live-activities-enabled -bool true
  "${d[@]}" write "$BUNDLE_ID" app.gethoshi.agent-live-activity-server-names -bool true
  "${d[@]}" write "$BUNDLE_ID" com.hoshi.security.appLockEnabled -bool false
  "${d[@]}" write "$BUNDLE_ID" com.hoshi.appearance.fontSize -float "${SHOTS_FONT_SIZE:-15}"
  # SHOTS_FONT picks a bundled terminal font (e.g. the video's JetBrains Mono).
  if [ -n "${SHOTS_FONT:-}" ]; then
    "${d[@]}" write "$BUNDLE_ID" com.hoshi.appearance.fontFamily "$SHOTS_FONT"
  else
    "${d[@]}" delete "$BUNDLE_ID" com.hoshi.appearance.fontFamily 2>/dev/null || true
  fi
  "${d[@]}" write "$BUNDLE_ID" com.hoshi.terminal.autoHideHeader -bool false
  # Key sets and theme live in the app container's plist, which the bundle-ID
  # domain above doesn't reach for these keys: address it by path, app quit.
  xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
  local c; c="$(xcrun simctl get_app_container "$udid" "$BUNDLE_ID" data)/Library/Preferences/$BUNDLE_ID"
  # Key sets start from the built-ins, or from a seed (SHOTS_KEY_SETS=path to
  # the JSON Hoshi stores, e.g. scripts/screenshots/seeds/key-sets-git-st.json).
  "${d[@]}" delete "$c" com.hoshi.toolbar.buttons 2>/dev/null || true
  if [ -n "${SHOTS_KEY_SETS:-}" ]; then
    "${d[@]}" write "$c" com.hoshi.keyProfiles.v1 -data "$(xxd -p "$SHOTS_KEY_SETS" | tr -d '\n')"
  else
    "${d[@]}" delete "$c" com.hoshi.keyProfiles.v1 2>/dev/null || true
  fi
  # Theme: SHOTS_THEME (a theme ID), else the app default.
  if [ -n "${SHOTS_THEME:-}" ]; then
    "${d[@]}" write "$c" com.hoshi.appearance.themeID "$SHOTS_THEME"
  else
    "${d[@]}" delete "$c" com.hoshi.appearance.themeID 2>/dev/null || true
  fi
}

# Servers + passwords + pinned host keys, as base64 JSON for ScreenshotSeed.
seed_json() {
  local pw; pw=$(cat "$SHOTS_ROOT/assets/screenshot-host/.shots-password")
  python3 - "$pw" <<'PY'
import base64, json, subprocess, sys
pw = sys.argv[1]
hosts = [
    # name, container, host, port, transport, udp range, favorite
    ("devbox", "devbox", "devbox.localhost", 2222, "auto", "60200:60209", True),
    ("gpu-box", "gpu-box", "gpu.localhost", 2223, "mosh", "60210:60219", False),
    ("prod-api", "prod-api", "api.localhost", 2224, "ssh", None, False),
]
servers, known = [], []
for name, container, host, port, transport, udp, fav in hosts:
    servers.append({"name": name, "hostname": host, "port": port, "username": "fcoury",
                    "password": pw, "transport": transport, "tmux": "alwaysAsk",
                    "udpPortRange": udp, "favorite": fav})
    for alg in ("ed25519", "ecdsa", "rsa"):
        key = subprocess.run(["docker", "exec", f"shots-{container}", "cat",
                              f"/etc/ssh/ssh_host_{alg}_key.pub"],
                             capture_output=True, text=True, check=True).stdout.strip()
        known.append({"hostname": host, "port": port, "key": key})
# A saved host that's never opened, so the list looks lived-in.
servers.append({"name": "homelab", "hostname": "pi.localhost", "port": 2299, "username": "pi",
                "password": "unused", "transport": "mosh", "tmux": "alwaysAsk"})
print(base64.b64encode(json.dumps({"servers": servers, "knownHosts": known}).encode()).decode())
PY
}

launch_app() {
  local udid=$1
  SIMCTL_CHILD_HOSHI_SCREENSHOT_SEED=$(seed_json) \
    xcrun simctl launch --terminate-running-process "$udid" "$BUNDLE_ID" >/dev/null
  sleep "${SHOTS_LAUNCH_WAIT:-3}"
}

# ---- AXe wrappers. Taps need a short pre-delay: AXe events sent while an
# animation is still running are dropped. The accessibility tree also lags
# the screen, so poll for elements instead of reading once.

tap_label() { axe tap --label "$2" --pre-delay "${3:-0.4}" --udid "$1" >/dev/null; }
tap_xy() { axe tap -x "$2" -y "$3" --pre-delay "${4:-0.4}" --udid "$1" >/dev/null; }

# Tap the first element whose AX label contains $2 (e.g. "hoshi, 1 window").
tap_prefix() {
  local udid=$1 prefix=$2 frame
  frame=$(wait_for "$udid" "$prefix") || return 1
  read -r x y w h <<<"$frame"
  tap_xy "$udid" $((x + w / 2)) $((y + h / 2))
}

# Prints "x y w h" of the first element whose label contains $2.
find_frame() {
  axe describe-ui --udid "$1" | python3 -c '
import json, sys
prefix = sys.argv[1]
def walk(n):
    if isinstance(n, list):
        for c in n: yield from walk(c)
        return
    yield n
    yield from walk(n.get("children") or [])
for n in walk(json.load(sys.stdin)):
    label = n.get("AXLabel") or ""
    if prefix in label and n.get("frame"):
        f = n["frame"]; print(int(f["x"]), int(f["y"]), int(f["width"]), int(f["height"])); break
' "$2"
}

wait_for() {
  local udid=$1 prefix=$2 timeout=${3:-20} frame
  for _ in $(seq $((timeout * 2))); do
    frame=$(find_frame "$udid" "$prefix")
    [ -n "$frame" ] && { echo "$frame"; return 0; }
    sleep 0.5
  done
  log "timed out waiting for '$prefix'"; return 1
}

shot() {
  local udid=$1 out=$2
  mkdir -p "$(dirname "$out")"
  xcrun simctl io "$udid" screenshot --type=png "$out" >/dev/null 2>&1
  log "captured ${out#$SHOTS_ROOT/}"
}

# Clean slate for one capture: restart the hosts (resets agents and OrbStack's
# UDP forwarding), clear app state, launch seeded.
fresh_launch() {
  local udid=$1 other
  # Hoshi on another simulator reconnects and attaches to the same tmux
  # sessions, shrinking every window to its size. Quit it there first.
  for other in $(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}'); do
    [ "$other" = "$udid" ] || xcrun simctl terminate "$other" "$BUNDLE_ID" 2>/dev/null || true
  done
  "$SHOTS_ROOT/scripts/screenshots/host.sh" restart >/dev/null
  app_defaults "$udid"
  launch_app "$udid"
}

# Connect to a seeded server from the list and wait for the session picker.
open_picker() {
  local udid=$1 login=$2
  tap_prefix "$udid" "$login"
  wait_for "$udid" "Open Raw Shell" 40 >/dev/null
  sleep 1
}
