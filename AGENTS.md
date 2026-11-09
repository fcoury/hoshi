# AGENTS.md

Project-specific instructions for agents working in this repo. Hoshi is an SSH
and Mosh terminal for iPhone and iPad: SwiftUI, GhosttyKit (Metal terminal
rendering), Citadel (SSH), a Mosh client written from scratch in Swift, and
tmux/Herdr integration. iOS 18.0+, Swift 5.9 language mode.

## Setup

Prerequisites: full Xcode with the iOS SDK and an iOS simulator runtime,
XcodeGen, and ripgrep (`brew install xcodegen ripgrep`).

```bash
# Fast path: download a prebuilt GhosttyKit (no Zig or Metal toolchain needed)
./scripts/bootstrap.sh --prebuilt

# Full path: build GhosttyKit from vendor/ghostty (needs zig@0.15 and the
# Metal toolchain; see README.md "Building")
./scripts/bootstrap.sh
```

Bootstrap initializes the `vendor/ghostty` and `vendor/libxev` submodules,
puts `GhosttyKit.xcframework` in `vendor/ghostty/macos/`, symlinks it into
`Hoshi/Frameworks/` (gitignored), and regenerates the Xcode project.
`HOSHI_GHOSTTYKIT_PREBUILT=1 ./scripts/build-ghosttykit.sh` reuses a
framework that is already in place.

## Project file

`Hoshi/project.yml` is the source of truth. Never edit
`Hoshi/Hoshi.xcodeproj/project.pbxproj` by hand. After changing `project.yml`,
or adding, removing, or renaming any source or resource file:

```bash
xcodegen --spec Hoshi/project.yml --project Hoshi
```

Commit the regenerated `project.pbxproj`. CI regenerates it and fails on
`git diff --exit-code` if it is stale. Version and build numbers live in
`project.yml` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`) for both the app
and the `HoshiLiveActivity` extension; keep them equal.

## Build and test

Use the simulator. Deploy to a device only when asked.

```bash
# Unit tests, as CI runs them (first available iPhone simulator)
simulator_id="$(xcrun simctl list devices available \
  | sed -nE 's/^[[:space:]]+iPhone[^()]*\(([A-Fa-f0-9-]+)\).*/\1/p' | head -n 1)"
xcodebuild test -project Hoshi/Hoshi.xcodeproj -scheme Hoshi \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 120 \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO

# One class or test
xcodebuild test ... -only-testing:HoshiTests/KeyProfileTests

# Self-hosted agent companion (Python standard library only)
python3 scripts/test-hoshi-agent-companion.py
```

CI (`.github/workflows/ci.yml`) also runs `gitleaks` over history. Never
commit tokens, passwords, keys, or `.p8` files.

### Live Mosh tests

`Hoshi/HoshiTests/MoshIntegrationTests.swift` skips unless its environment is
set. xcodebuild forwards variables to the test runner only with the
`TEST_RUNNER_` prefix.

- `testMoshConnectAndEcho`: full SSH bootstrap plus Mosh against a reachable
  host with `mosh-server` installed, on port 22. Set `HOSHI_MOSH_HOST`,
  `HOSHI_MOSH_USER`, `HOSHI_MOSH_PASSWORD`. The host key must already be
  trusted in that simulator (connect once from the app), or the session stops
  at the trust prompt.
- `testLocalMoshServerScenario`: skips SSH and drives a `mosh-server` you
  started yourself. Run `mosh-server new -p <port> -- <program>`, read the
  `MOSH CONNECT <port> <key>` line, and set `HOSHI_MOSH_LOCAL_PORT`,
  `HOSHI_MOSH_LOCAL_KEY`, optionally `HOSHI_MOSH_LOCAL_HOST` (default
  127.0.0.1) and `HOSHI_MOSH_CAPTURE=<file>` (base64 chunk per line). The
  program must print `prompt$`, read one line, print `GOT:<line>`, then
  `__SCENARIO_DONE__`. The Docker image in `assets/screenshot-host/` ships
  sshd and mosh, and its compose file publishes UDP 60200-60229 on loopback,
  so it can host that `mosh-server` (`scripts/screenshots/host.sh up`).

```bash
TEST_RUNNER_HOSHI_MOSH_LOCAL_PORT=60200 TEST_RUNNER_HOSHI_MOSH_LOCAL_KEY=... \
  xcodebuild test ... -only-testing:HoshiTests/MoshIntegrationTests
```

## Module map (`Hoshi/Hoshi/`)

- `HoshiApp.swift`: app entry; registers bundled fonts with Core Text before Ghostty starts; SwiftData container for `Server`.
- `Models/`: value types and persisted models. `Server` (SwiftData profile, no secrets), `KeyProfile` (key sets, `KeyProfileResolver`, `HerdrKeyImport`), `ToolbarButton`, `TerminalTheme`, `TmuxCommand`, `Herdr` (CLI JSON models), `AgentEvent`, `AgentLiveActivityAttributes` (shared with the widget extension), `ConnectionPolicy`, `SSHConnectionError`.
- `Services/SSHConnectionService.swift`: the single Citadel `SSHClient.connect` call site; authentication plus host-key validation for every transport.
- `Services/KnownHostsService.swift`, `KeychainService.swift`, `SSHKeyService.swift`: host-key trust, Keychain storage, on-device key generation.
- `Services/ConnectionCoordinator.swift`: one verified SSH bootstrap, then picks SSH or Mosh.
- `Services/SSHService.swift`, `MoshSession.swift`, `SessionProtocol.swift`: the two terminal transports behind `TerminalSession`.
- `Services/MoshBootstrapService.swift`, `Services/Mosh/`: starting `mosh-server` over SSH, launch-failure diagnosis, and the Mosh protocol itself (UDP transport, SSP state sync, AES-OCB crypto).
- `Services/Tmux*`, `HerdrAgentMonitor.swift`: tmux detection/settings and Herdr agent state, over the verified SSH connection.
- `Services/Agent*`: agent events (OSC decoder, inbox, persistence, notifications, Live Activities, deep links, optional companion polling).
- `Services/RemoteFileBrowserService.swift`, `FileUploadService.swift`: SFTP browse/download/upload with private, bounded staging.
- `Services/AppearanceSettings.swift`, `ToolbarConfigurationService.swift`, `KeyProfileStore.swift`: UserDefaults-backed preferences.
- `Services/AppLockService.swift`, `VoicePromptService.swift`, `NetworkMonitorService.swift`, `HapticService.swift`, `ErrorPresentation.swift`, `TerminalIdentity.swift`; `ScreenshotSeed.swift` is `#if DEBUG` only.
- `Terminal/`: the Ghostty bridge. `GhosttyRuntimeController` (C callbacks, clipboard), `GhosttyTerminalView` (UIView, input, gestures), `GhosttyThemeAdapter` (theme to Ghostty config), `KeyChord` (chord notation to bytes), `TerminalInteraction` (paste and clipboard policy), arrow pad.
- `ViewModels/`: `SessionManager` (up to five sessions), `ManagedSession`, `ConnectionViewModel`, `SessionPersistence` (resume metadata only).
- `Views/`: SwiftUI screens: server list, add server, connect, terminal, session carousel, toolbar and key-set editors, settings, host-key trust, tmux/Herdr pickers, agent inbox, file browser, voice composer.
- `Tips/`: TipKit tips. `Resources/`: bundled Nerd Fonts and `PrivacyInfo.xcprivacy`.
- `Hoshi/HoshiLiveActivity/`: the WidgetKit extension. `Hoshi/HoshiTests/`: XCTest suite.
- `scripts/hoshi-agent-companion.py`: optional self-hosted event companion; protocol in `docs/agent-events.md`.

## Invariants (do not regress)

- **Host keys are verified.** Every SSH connection goes through
  `SSHConnectionService.connect`, which uses `KnownHostsService`'s validator:
  unknown keys fail with `.untrusted` and go to the trust prompt, changed keys
  fail with `.changed`. Never pass an accept-anything validator.
- **Secrets live only in the Keychain** (`KeychainService`,
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`): passwords, private keys,
  known host keys, the companion bearer token. Never in `Server`, UserDefaults,
  session persistence, the event archive, logs, or error context.
- **Approvals never execute anything.** `approval_requested` events only open
  the related terminal; any `command` field from the remote is dropped and not
  persisted (`AgentMonitoringTests`). Deep links (`hoshi://inbox|session|server`)
  carry only UUIDs.
- **No telemetry.** No analytics, ads, crash reporters, or third-party SDKs;
  `PrivacyInfo.xcprivacy` declares no tracking. Network traffic is limited to
  the user's servers (SSH, SFTP, Mosh UDP) and their configured companion,
  which must be HTTPS (plain HTTP only for loopback), never follows redirects,
  and bounds response size.
- **Dangerous pastes need confirmation.** `TerminalPastePolicy.assess` flags
  multiline text without bracketed paste, large pastes, and embedded
  bracketed-paste terminators; cancelling sends nothing.
- **Remote clipboard (OSC 52) asks by default** for reads and writes, fails
  closed when no prompt can be shown, and is size-bounded.
- **Voice is on device.** Speech recognition stays local and audio is captured
  only while the user holds the button; the draft is editable before sending.
- **Live Activities** never carry terminal output, event messages, or
  credentials (`AgentLiveActivityAttributes`).
- `TERM` stays `xterm-256color` (`TerminalIdentity`).
- `ghostty_surface_binding_action` takes the action's byte length:
  `UInt(action.utf8.count)`, never a literal.

## Common contributions

**A built-in key set** (`Hoshi/Hoshi/Models/KeyProfile.swift`). `KeyProfile`
has `id`, `name`, an SF Symbol `symbol`, `matchPatterns`, an optional
`prefix` chord, and `keys: [ToolbarButton]`. Add an ID constant, a
`static var` built like `vim` or `pager`, and add it to both `builtIns` and
`builtInOrder`. `KeyProfileResolver` checks a pin, then an attached set (Herdr),
then the first set in `builtInOrder` whose pattern matches the terminal title,
then Shell. Single-word patterns match whole title words (lowercased, split on
anything but letters, digits, `-`, `_`), so `top` does not match `Desktop`;
patterns with spaces or punctuation match as substrings. Keys are built-ins
(`.esc`, `.ctrlC`, `.arrowUp`, `.paste`, ...) or
`.custom(label:chord:symbol:id:)` with a stable `id` and `KeyChord` notation
(`ctrl+b`, `shift+tab`, `alt+enter`, `prefix+c`, `:w enter`). New IDs appear
for existing users through `KeyProfileStore.merge`; once a user has saved key
sets, their saved copy of an existing set wins until they reset it. Add a
resolver case to `KeyProfileTests` in `TerminalInteractionTests.swift`.

**A theme** (`Hoshi/Hoshi/Models/TerminalTheme.swift`). Add a `static let`
with a unique, stable `id`, 16 palette colors in standard ANSI order (app
accents read slots 1 to 6), background, foreground, cursor, and selection
colors, then append it to `allThemes`. The ID is persisted, so never rename
one. Check both the terminal and the app chrome on the simulator.

**A font.** Put the `.ttf`/`.otf` files in `Hoshi/Hoshi/Resources/Fonts/`
(Nerd Font Mono variants, with their license), regenerate the project, and add
the Core Text family name to `bundledFonts` in
`Hoshi/Hoshi/Views/FontPickerView.swift`. `HoshiApp.registerBundledFonts()`
registers every bundled font at launch.

## Commit Message Guidelines

- Use Angular-style commit messages (e.g., `feat: ...`, `chore: ...`) and include a short detail summary in the body.
