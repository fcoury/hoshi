# App Store screenshots

Real app, real terminal, scripted end to end. Hoshi runs in the iOS Simulator
against three Docker containers (`devbox`, `gpu-box`, `prod-api`) whose every
byte of terminal output is scripted, so each run produces the same frames.

```
assets/screenshot-host/   Docker image: sshd, mosh, tmux, Herdr, scripted agents
scripts/screenshots/      host.sh, capture.sh, sync.sh, trigger.sh, lib.sh
assets/screenshot-generator/   Next.js slides + Playwright export
```

## Requirements

- Xcode 27 simulators: iPhone 17 Pro (1206×2622) and iPad Pro 13-inch (M5)
- Docker (OrbStack), ffmpeg, bun
- AXe: `brew install cameroncooke/axe/axe`

## Run it

```bash
scripts/screenshots/host.sh up              # build + start the hosts (once)
scripts/screenshots/capture.sh iphone-6.3   # builds Hoshi (Debug), captures
scripts/screenshots/capture.sh ipad-13
scripts/screenshots/sync.sh                 # raw captures -> generator
cd assets/screenshot-generator && bun install && bun run export
```

Raw captures land in `.shots/raw/<device>/` (gitignored). Exports land in
`assets/screenshots/{iphone-6.9,ipad-13}/`, sized for App
Store Connect with no alpha channel. Preview the slides with `bun dev`.

`SKIP_BUILD=1` reuses the last build; a second argument picks runs, e.g.
`capture.sh iphone-6.3 agents`.

## App Preview video

```bash
scripts/screenshots/preview.sh iphone-6.3          # records two takes
(cd assets/screenshot-generator && bun run export -- --cards)
node scripts/screenshots/compose-preview.mjs       # -> assets/app-preview/iphone-6.9.mp4
```

`preview.sh` records the `agents` take (picker, the builder streaming live,
Lock Screen reply) and the `terminal` take (tmux, vim, joystick) with
`simctl io recordVideo`, logging marks and touches beside each `.mov`. The
terminal font is JetBrains Mono for the video (`SHOTS_FONT`). The builder waits
for `trigger.sh start` (`SHOTS_HOLD=2`) so its work streams in on camera.

`compose-preview.mjs` cuts segments relative to those marks, so a new take
needs no retiming. It speeds up typing, draws touch dots, and crossfades to
the JetBrains Mono title cards. Output is 886×1920, 30 fps, H.264 High with a
silent stereo AAC track, 15–30 s: the App Preview spec for 6.9" and 6.5"
iPhones. Edit `PLAN` in the script to change the cut.

## Real Codex (opt-in)

The site's agent shot is the real Codex, not the scripted agent. Hoshi
connects to devbox and attaches to Herdr; the Builder pane runs `ssh` back to
this Mac, where a forced command starts Codex in this repo, read-only.

```bash
scripts/screenshots/codex.sh setup                       # once; needs Remote Login + signed-in codex
SKIP_BUILD=1 scripts/screenshots/capture.sh iphone-6.3 codex   # codex-working.png, codex.png
scripts/screenshots/codex.sh remove                      # undo setup
```

`setup` adds one `hoshi-shots-codex` line to `~/.ssh/authorized_keys` (backup
beside it). That key can only run `codex -s read-only -a never` in this repo
with the prompt the client sends: no shell, no forwarding. Herdr recognises
agents by process name, so the ssh client runs from a copy named `codex` and
the pane lists as a real Codex agent. `codex.sh swap "PROMPT"` changes the
task. Runs are live, so the answer and timing differ each time, and each one
uses a little of your Codex quota.

Site images are 560 px wide JPEGs of the raw captures:
`sips -s format jpeg -s formatOptions 80 --resampleWidth 560 IN.png --out assets/site/img/NAME.jpg`.

## How it stays deterministic

- **Seeded app.** Debug builds read `HOSHI_SCREENSHOT_SEED` (base64 JSON,
  `Hoshi/Hoshi/Services/ScreenshotSeed.swift`): servers, Keychain passwords and
  pinned host keys, so no trust prompts. Settings, cleared session restore and
  the cleared agent inbox are plain UserDefaults written by `lib.sh`. Release
  builds don't contain any of it.
- **Scripted agents.** `agent.py` plays fixed transcripts in real Herdr panes and
  reports `working`/`blocked`/`idle` with `herdr pane report-agent`, so Hoshi's
  Herdr list, inbox and Live Activity are genuine. The reviewer's approval
  prompt reads stdin, so Hoshi's Reply really continues it.
- **Held moments.** With `SHOTS_HOLD=1` the reviewer and writer wait for
  `trigger.sh block|finish`, so Hoshi sees those changes happen live and raises
  the Live Activity.
- **Fixed chrome.** 9:41 status bar, dark mode, US English, no spell-check
  squiggles, 15 pt terminal font, header pinned while typing.

## Gotchas

- **Restart the hosts before each launch** (`fresh_launch` does). OrbStack's
  IPv6 UDP forwarding wedges when a killed app leaves a mosh-server sending to
  it, and `*.localhost` resolves to `::1` first.
- **AXe taps need a pre-delay** (0.4–1 s) after animations, or they're dropped.
- **The accessibility tree goes stale** while a terminal is on screen, so taps
  inside a session use coordinates (listed per device in `capture.sh`).
- **No Dynamic Island content** in Simulator screenshots, and no 5G label on
  Dynamic Island phones. The Lock Screen Live Activity captures fine.
- **No rotation** from scripts on Xcode 27 (no Simulator.app), and iPadOS
  ignores app orientation requests, so the iPad set is portrait.
- First run on a fresh simulator shows system prompts (Live Activities, speech
  recognition); `capture.sh` taps through them.
