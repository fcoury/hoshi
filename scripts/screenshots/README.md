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
