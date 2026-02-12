# Hoshi (星) — Product Requirements Document

**Version:** 1.0
**Author:** Felipe (via Claude)
**Date:** February 11, 2026
**Status:** Draft

---

## 1. Overview

**Hoshi** (星, "star" in Japanese) is an open-source iOS terminal app built for monitoring and interacting with AI coding agents running on remote servers. It connects via Mosh (Mobile Shell) or SSH, auto-detects tmux sessions, and provides a purpose-built mobile interface for developers who need to check on, nudge, and unblock their agents from anywhere.

The name riffs on **Moshi** (もしもし, "hello" — the start of every phone call) while evoking a star watching over your agents from afar. Hoshi is a personal tool first, open-sourced for the community.

### Core Philosophy

- **Agent monitor, not a general-purpose terminal.** Every design decision optimizes for the workflow: connect → pick tmux session → check agent status → send input → disconnect.
- **Phone-first keyboard design.** No shrunken desktop metaphors. The keyboard is the product — customizable, ergonomic, with a tmux command palette that eliminates awkward key chording.
- **Resilient by default.** Mosh protocol keeps sessions alive through network switches, sleep, and subway tunnels. You never lose your connection.

---

## 2. Problem Statement

### The Workflow Gap

AI coding agents (Claude Code, Codex, Aider, etc.) run long-lived sessions on remote servers. Developers need to periodically check on them, approve changes, answer questions, or restart failed tasks. This happens from the couch, the train, bed — not always at a desk.

### What Exists Today

| App                  | Strengths                                                        | Weaknesses                                                                                                 |
| -------------------- | ---------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| **Moshi**            | Beautiful, Mosh-native, tmux integration, voice input, free beta | Keyboard toolbar discoverability poor (hidden swipe), no custom key combos, limited keyboard customization |
| **Blink Shell**      | Mature, open-source, powerful                                    | Complex, subscription model ($19.99/yr), not optimized for agent monitoring                                |
| **Termius**          | Cross-platform, polished                                         | Subscription-heavy, bloated for this use case, Mosh requires paid plan                                     |
| **Secure ShellFish** | Solid SSH, good snippets                                         | No native Mosh, less focused on agent workflow                                                             |

### What Hoshi Does Differently

1. **Tmux command palette** — A dedicated button that opens a submenu of your most-used tmux actions (zoom, navigate panes, split, kill), all bound to your custom prefix. No more trying to chord Ctrl+S on a phone keyboard.
2. **Fully customizable keyboard toolbar** — Drag-to-reorder buttons, choose exactly which keys appear, no hidden swipe gestures.
3. **Session picker as a first-class screen** — Every connection starts with a tmux session list. This is the home screen, not an afterthought.
4. **Personal-first design** — No account system, no cloud sync, no subscription. Tailored to a power user's exact workflow.

---

## 3. Target User

**Primary:** Felipe (the author) — a software developer and AI consultant who runs multiple AI coding agents across servers, uses tmux extensively with a custom prefix (Ctrl+S), and needs quick mobile access to monitor and interact with agents.

**Secondary:** Developers in the AI agent ecosystem who share a similar workflow and discover Hoshi through GitHub.

### User Persona

- Runs Claude Code, Codex, or similar agents in tmux sessions on a Mac Mini / VPS
- Uses Tailscale or direct SSH for connectivity
- Connects from iPhone multiple times per day for quick check-ins (1–5 minutes each)
- Has a custom tmux configuration with Ctrl+S as prefix
- Values speed-to-session over feature breadth

---

## 4. Feature Requirements

### 4.1 v1 — Core (MVP)

#### P0: Connection Protocols

- **Mosh (Mobile Shell)** — Primary protocol. UDP-based, survives network changes, sleep, roaming.
  - Support custom UDP port ranges
  - Mosh-server path configuration
  - Automatic reconnection with visual status indicator
- **SSH** — Fallback protocol for servers without Mosh.
  - Ed25519, RSA, ECDSA key support
  - Password authentication
  - SSH agent forwarding
  - ProxyCommand / jump host support
- **Connection profiles** — Save server configurations with:
  - Hostname / IP
  - Port
  - Username
  - Auth method (key / password)
  - Protocol preference (Mosh preferred, SSH fallback)
  - Custom Mosh server path and UDP port range
  - Quick-connect favorites (single tap to connect)

#### P0: Tmux Session Auto-Detect & Picker

This is the **hero screen** of the app. Upon connecting to any server:

1. App runs `tmux list-sessions` automatically
2. Displays session list with:
   - Session name
   - Number of windows
   - Created / last attached timestamp
   - Attached status (is someone else on it?)
3. User selects a session → `tmux attach -t <session>`
4. Option to create a new session
5. Option to skip tmux and go straight to shell
6. **Always show the picker** — even with one session. This is a deliberate UX choice for consistency and awareness.

**Session picker design:**

- Full-screen modal with dark background
- Sessions as large, tappable cards
- Visual distinction between attached/detached sessions
- Pull-to-refresh to re-scan sessions
- "New Session" button prominently placed
- "Raw Shell" option at the bottom

#### P0: Terminal Emulator

- **xterm-256color** compatible terminal
- Proper monospace font rendering with correct character cell calculations
- Support for Unicode / UTF-8, including CJK characters
- True color (24-bit) support
- Scrollback buffer (configurable depth)
- Pinch-to-zoom for font size adjustment
- Selection and copy support (long-press to select, drag handles)
- Paste from clipboard

#### P0: Keyboard System

The keyboard is the most critical UX element. Three layers:

**Layer 1: iOS System Keyboard**
Standard text input with autocorrect disabled by default.

**Layer 2: Customizable Toolbar**
A single row of buttons above the keyboard:

- **Fully customizable** — user picks which buttons appear and their order
- **Drag-to-reorder** in settings
- Available buttons include: Ctrl, Esc, Tab, Up, Down, Left, Right, Pipe (|), Slash (/), Tilde (~), Dash (-), Underscore (\_), and any user-defined key combos
- Clear visual labels, large enough tap targets (minimum 44pt)
- No hidden gestures — everything visible or explicitly configured

**Layer 3: Tmux Command Palette**
A dedicated "tmux" button on the toolbar that opens a submenu/popup:

```
┌─────────────────────────────┐
│  Tmux Actions (Ctrl+S + )   │
├─────────────────────────────┤
│  ↕ Zoom Pane         (z)   │
│  ← Left Pane         (h)   │
│  → Right Pane        (l)   │
│  ↑ Up Pane           (k)   │
│  ↓ Down Pane         (j)   │
│  ─ Split Horizontal  (-)   │
│  │ Split Vertical    (|)   │
│  ✕ Kill Pane         (x)   │
│  n Next Window       (n)   │
│  p Prev Window       (p)   │
│  d Detach            (d)   │
│  [ Copy Mode         ([)   │
│  : Command Prompt    (:)   │
└─────────────────────────────┘
```

Key behaviors:

- Tapping a tmux action sends: `<prefix>` + `<key>` (e.g., Ctrl+S then z for zoom)
- **Prefix is configurable** in settings (default: Ctrl+B, user sets to Ctrl+S or whatever)
- Actions are **user-customizable** — add, remove, reorder, rename
- Support for **custom key sequences** (e.g., user can add "resize-pane -R 5" as a named action)
- Submenu appears as a bottom sheet or popup, dismissible by tapping outside
- Haptic feedback on action execution

#### P0: Terminal Themes

Built-in dark themes:

- **Nord** (default)
- **Dracula**
- **Solarized Dark**
- **Tokyo Night**
- **Catppuccin Mocha**
- **Gruvbox Dark**
- **One Dark**

Theme configuration:

- Background, foreground, cursor, selection colors
- ANSI 16-color palette
- Bold color variants
- Font selection (system monospace fonts)
- Font size (with pinch-to-zoom override)

**Dark-only design** — no light themes. The entire app UI is dark.

#### P1: Push Notifications (Webhook Alerts)

Receive notifications when long-running tasks complete:

- App generates a unique webhook URL per device
- User adds a `curl` command to their scripts:
  ```bash
  curl -X POST https://hoshi.app/webhook/<token> -d '{"title": "Build Complete", "body": "✅ All tests passed"}'
  ```
- Or a simpler shell function:
  ```bash
  hoshi-notify() { curl -s -X POST "https://hoshi.app/webhook/$HOSHI_TOKEN" -d "{\"title\":\"$1\"}"; }
  ```
- Push notification appears on iPhone with custom title/body
- Tapping notification opens Hoshi and reconnects to the relevant server
- **Self-hostable** webhook relay server (open-source Go/Rust binary)
- Option to use a free hosted relay during beta

#### P1: Multi-Server Session Switcher

- Maintain multiple simultaneous connections
- Swipe gesture or tab bar to switch between active sessions
- Visual indicator showing which sessions are active
- Quick-connect from session switcher (recently connected servers)
- Session auto-recovery after iOS kills the app in background

#### P2: Voice-to-Terminal

- On-device speech recognition (Apple Speech framework)
- Optional Whisper model for higher accuracy
- Long-press microphone button to dictate
- Visual transcription preview before sending
- Optimized for command dictation (recognizes technical terms)

#### P2: Face ID / Touch ID for SSH Keys

- SSH private keys stored in iOS Keychain
- Biometric unlock required to use keys
- Import keys via:
  - Paste from clipboard
  - AirDrop
  - Files app
- In-app key generation (Ed25519)
- Key management UI (list, delete, rename)

### 4.2 v2 — Planned Enhancements

- **Tailscale integration** — Discover and connect to Tailscale nodes automatically
- **Clipboard sync** — Bidirectional clipboard between phone and server (via OSC 52 or custom mechanism)
- **SFTP file browsing** — Browse and transfer files
- **Inline image preview** — Render images in terminal (iTerm2 protocol)
- **Snippets / saved commands** — Quick-fire frequently used commands
- **Apple Watch companion** — Notification management and quick status glance
- **iPad support** — Split-screen, external keyboard optimization

---

## 5. Technical Architecture

### 5.1 Platform & Stack

| Component             | Technology                                                      |
| --------------------- | --------------------------------------------------------------- |
| **Platform**          | iOS 17+ (Swift 6, SwiftUI)                                      |
| **Terminal Emulator** | SwiftTerm (open-source Swift terminal emulator) or custom fork  |
| **SSH Library**       | NMSSH or SwiftNIO SSH                                           |
| **Mosh**              | Compiled mosh-client from source (C++) via Xcode framework      |
| **Keychain**          | iOS Keychain Services API with biometric access control         |
| **Notifications**     | APNs (Apple Push Notification service)                          |
| **Webhook Relay**     | Lightweight self-hostable server (Rust or Go)                   |
| **Speech**            | Apple Speech framework + optional Whisper (Core ML)             |
| **Storage**           | SwiftData for connection profiles, UserDefaults for preferences |

### 5.2 Architecture Principles

- **No cloud dependency** — Everything runs locally except optional push notification relay
- **No accounts** — No login, no registration, no cloud sync
- **Offline-first** — Connection profiles and settings stored locally
- **Minimal permissions** — Only request what's needed (network, notifications, microphone for voice, Face ID)

### 5.3 Mosh Integration

Mosh is a C++ project. Integration approach:

1. Cross-compile mosh-client as an iOS framework using Xcode
2. Wrap in Swift via C bridging header
3. Handle UDP socket management within iOS networking constraints
4. Background execution strategy:
   - Use `beginBackgroundTask` for short extensions
   - Mosh's state synchronization protocol handles reconnection after iOS suspends the app
   - Store last-known terminal state for instant visual restoration

### 5.4 Terminal Rendering

Critical requirements:

- Correct monospace character cell calculations (especially for CJK wide characters)
- Proper handling of combining characters and emoji
- tmux pane border rendering (box-drawing characters must align perfectly)
- 60fps scrolling performance
- Metal-accelerated rendering for large scrollback buffers

### 5.5 Tmux Detection

On connection, the app runs:

```bash
tmux list-sessions -F '#{session_name}|#{session_windows}|#{session_created}|#{session_attached}|#{session_activity}'
```

Parsing this output populates the session picker. If tmux is not installed or no sessions exist, the picker shows "No sessions found" with options to create one or go to raw shell.

---

## 6. UX & Design Specifications

### 6.1 Design Language

- **Dark-only UI** — Deep blacks (#000000) with subtle dark grays (#1a1a1a, #2a2a2a)
- **Accent color** — Soft blue or purple (configurable)
- **Typography** — SF Pro for UI, SF Mono / user-selected monospace for terminal
- **Animations** — Subtle, fast (< 200ms), iOS-native spring curves
- **Iconography** — SF Symbols throughout, minimal custom assets

### 6.2 Navigation Flow

```
┌──────────────┐
│  Server List  │ ← Home screen. Saved servers as cards.
│  + Add Server │    Quick-connect favorites at top.
└──────┬───────┘
       │ tap server
       ▼
┌──────────────┐
│  Connecting   │ ← Mosh/SSH handshake with progress animation
└──────┬───────┘
       │ connected
       ▼
┌──────────────┐
│ Tmux Picker   │ ← Session cards. Always shown.
│               │    Pull-to-refresh. "New" and "Raw Shell" options.
└──────┬───────┘
       │ select session
       ▼
┌──────────────┐
│  Terminal     │ ← Full-screen terminal with keyboard toolbar
│  + Keyboard   │    Tmux command palette accessible from toolbar
│  + Palette    │
└──────────────┘
```

### 6.3 Gestures

| Gesture                         | Action                                          |
| ------------------------------- | ----------------------------------------------- |
| Swipe up from keyboard          | Open session switcher (if multiple connections) |
| Pinch                           | Adjust terminal font size                       |
| Long-press on terminal          | Text selection mode                             |
| Two-finger tap                  | Paste from clipboard                            |
| Swipe left/right on toolbar     | Scroll through toolbar buttons (if overflow)    |
| Swipe down from top of terminal | Reveal connection info bar                      |

### 6.4 Session Switcher

When multiple connections are active:

- Horizontal card carousel or vertical list
- Each card shows: server name, tmux session name, last activity timestamp
- Visual indicator for sessions with new output since last viewed
- Swipe to disconnect individual sessions

---

## 7. Keyboard Configuration Detail

### 7.1 Settings Screen

```
Keyboard Settings
─────────────────
Toolbar Buttons
  [Drag handles] Esc
  [Drag handles] Ctrl
  [Drag handles] Tab
  [Drag handles] Tmux ★
  [Drag handles] ↑
  [Drag handles] ↓
  [Drag handles] ←
  [Drag handles] →
  [+ Add Button]

Tmux Prefix: Ctrl+S  [Change]

Tmux Actions
  [Drag handles] Zoom Pane (z)
  [Drag handles] Left Pane (h)
  [Drag handles] Right Pane (l)
  [Drag handles] Up Pane (k)
  [Drag handles] Down Pane (j)
  [Drag handles] Split H (-)
  [Drag handles] Split V (|)
  [Drag handles] Kill Pane (x)
  [Drag handles] Next Window (n)
  [Drag handles] Prev Window (p)
  [Drag handles] Detach (d)
  [Drag handles] Copy Mode ([)
  [Drag handles] Command (:)
  [+ Add Custom Action]

Custom Action Editor
  Name: [____________]
  Key Sequence: [____] (e.g., "resize-pane -R 5")
  Send as: ○ Prefix + Key  ○ Raw Command  ○ tmux send-keys
```

### 7.2 Custom Key Combo Definition

Users can define arbitrary key combos as toolbar buttons:

- **Name**: Display label on the button
- **Sequence**: The actual keystrokes to send
- **Type**: Single key, modifier+key, or multi-key sequence

Examples:

- "Prefix" → sends Ctrl+S
- "Save" → sends Ctrl+X, Ctrl+S (for Emacs)
- "Exit" → sends "exit\n"
- "Clear" → sends Ctrl+L

---

## 8. Data Model

### 8.1 Server Profile

```swift
struct ServerProfile: Identifiable, Codable {
    let id: UUID
    var name: String
    var hostname: String
    var port: Int                    // default 22
    var username: String
    var authMethod: AuthMethod       // .key(id), .password, .agent
    var protocol: ConnectionProtocol // .moshPreferred, .sshOnly, .moshOnly
    var moshServerPath: String?      // custom mosh-server binary path
    var moshPortRange: ClosedRange<Int>? // e.g., 60001...60010
    var isFavorite: Bool
    var lastConnected: Date?
    var sortOrder: Int
}
```

### 8.2 Keyboard Configuration

```swift
struct KeyboardConfig: Codable {
    var toolbarButtons: [ToolbarButton]   // ordered list
    var tmuxPrefix: KeyCombo              // default: Ctrl+B
    var tmuxActions: [TmuxAction]         // ordered list
}

struct ToolbarButton: Identifiable, Codable {
    let id: UUID
    var label: String
    var type: ButtonType  // .builtIn(.ctrl), .builtIn(.esc), .tmuxPalette, .custom(KeyCombo)
}

struct TmuxAction: Identifiable, Codable {
    let id: UUID
    var label: String
    var icon: String          // SF Symbol name
    var keySequence: String   // what to send after prefix
    var sendMode: SendMode    // .prefixThenKey, .rawCommand, .sendKeys
}

struct KeyCombo: Codable {
    var modifiers: [Modifier] // .ctrl, .alt, .shift
    var key: String           // "s", "b", "[", etc.
}
```

### 8.3 Theme

```swift
struct TerminalTheme: Identifiable, Codable {
    let id: String            // "nord", "dracula", etc.
    var name: String
    var background: Color
    var foreground: Color
    var cursor: Color
    var selection: Color
    var ansiColors: [Color]   // 16 ANSI colors
    var boldColors: [Color]?  // optional bold variants
}
```

---

## 9. Open-Source Strategy

### Repository

- **Name**: `hoshi` or `hoshi-terminal`
- **License**: MIT
- **Hosting**: GitHub

### Structure

```
hoshi/
├── Hoshi/                    # iOS app target
│   ├── App/                  # App entry point, navigation
│   ├── Views/                # SwiftUI views
│   ├── ViewModels/           # Observable objects
│   ├── Models/               # Data models
│   ├── Services/             # SSH, Mosh, tmux, notifications
│   ├── Keyboard/             # Toolbar, command palette
│   └── Terminal/             # Terminal emulator integration
├── HoshiRelay/               # Webhook relay server (Rust/Go)
├── Scripts/                  # Build scripts, mosh compilation
├── Docs/                     # Documentation
├── LICENSE
└── README.md
```

### Contribution Model

- Felipe is the primary maintainer and user
- Issues and PRs welcome but not the priority
- Clear "built for one person, shared with everyone" messaging

---

## 10. Development Phases

### Phase 1: Foundation (Weeks 1–3)

- [ ] Xcode project setup with SwiftUI
- [ ] SSH connection via NMSSH or SwiftNIO SSH
- [ ] Basic terminal emulator integration (SwiftTerm)
- [ ] Server profile CRUD (SwiftData)
- [ ] Connect → terminal → type → disconnect flow working end-to-end

### Phase 2: Tmux & Mosh (Weeks 4–6)

- [ ] Tmux session detection (`tmux list-sessions` parsing)
- [ ] Tmux session picker UI
- [ ] Mosh protocol integration (compile mosh-client for iOS)
- [ ] Mosh reconnection and state restoration
- [ ] Protocol fallback (Mosh → SSH)

### Phase 3: Keyboard System (Weeks 7–8)

- [ ] Customizable toolbar with drag-to-reorder
- [ ] Tmux command palette (submenu)
- [ ] Custom key combo definitions
- [ ] Configurable tmux prefix
- [ ] Haptic feedback

### Phase 4: Polish & Features (Weeks 9–11)

- [ ] Terminal themes (Nord, Dracula, Solarized, etc.)
- [ ] Push notification webhook system
- [ ] Self-hostable relay server
- [ ] Multi-server session switcher
- [ ] Pinch-to-zoom, gestures
- [ ] Quick-connect favorites

### Phase 5: Secondary Features (Weeks 12–14)

- [ ] Voice-to-terminal (Apple Speech)
- [ ] Face ID for SSH keys
- [ ] In-app key generation
- [ ] Settings polish
- [ ] App Store submission

### Phase 6: v2 Planning

- Tailscale integration
- Clipboard sync
- iPad support

---

## 11. Risks & Mitigations

| Risk                                | Impact | Mitigation                                                                                        |
| ----------------------------------- | ------ | ------------------------------------------------------------------------------------------------- |
| Mosh compilation for iOS is complex | High   | Start with SSH-only, add Mosh incrementally. Blink Shell's open-source Mosh fork is a reference.  |
| iOS background execution limits     | Medium | Mosh's protocol handles reconnection gracefully. Store terminal state for instant visual restore. |
| Terminal rendering performance      | Medium | Use Metal-backed rendering. Profile early with large scrollback.                                  |
| App Store rejection (terminal apps) | Low    | Terminal apps are well-established on the App Store (Blink, Termius, Prompt).                     |
| Webhook relay hosting costs         | Low    | Self-hostable. Free tier can use a minimal VPS or serverless function.                            |

---

## 12. Success Criteria

Since this is a personal tool, success is measured by:

1. **Felipe uses Hoshi daily** instead of Moshi or any other terminal app
2. **Connect-to-session time < 5 seconds** — tap server → pick session → interacting with agent
3. **Zero keyboard frustration** — every common tmux action is one or two taps away
4. **Never lose a session** — Mosh keeps the connection alive, app restores state after iOS kills it
5. **Push notifications work reliably** — know when an agent task completes without checking manually

---

## 13. Appendix

### A. Competitive Feature Matrix

| Feature                 | Hoshi (v1)           | Moshi               | Blink Shell | Termius   |
| ----------------------- | -------------------- | ------------------- | ----------- | --------- |
| Mosh protocol           | ✅                   | ✅                  | ✅          | ✅ (paid) |
| SSH                     | ✅                   | ✅                  | ✅          | ✅        |
| Tmux session picker     | ✅ (first-class)     | ✅                  | ❌          | ❌        |
| Tmux command palette    | ✅                   | ❌                  | ❌          | ❌        |
| Custom keyboard toolbar | ✅ (drag-to-reorder) | Partial (swipeable) | ✅          | ✅        |
| Custom key combos       | ✅                   | ❌                  | ✅          | Partial   |
| Push notifications      | ✅                   | ✅                  | ❌          | ❌        |
| Voice input             | v1.1                 | ✅                  | ❌          | ✅        |
| Face ID for keys        | v1.1                 | ✅                  | ✅          | ✅        |
| Terminal themes         | ✅                   | ✅                  | ✅          | ✅        |
| Open source             | ✅                   | ❌                  | ✅          | ❌        |
| Price                   | Free                 | Free (beta)         | $19.99/yr   | Freemium  |

### B. Key References

- **Moshi app**: https://getmoshi.app — Primary inspiration
- **Blink Shell**: https://blink.sh — Open-source reference for Mosh on iOS
- **SwiftTerm**: https://github.com/migueldeicaza/SwiftTerm — Terminal emulator library
- **Mosh protocol**: https://mosh.org — Protocol documentation
- **NMSSH**: https://github.com/NMSSH/NMSSH — Cocoa SSH library

### C. tmux Prefix Configuration

Hoshi defaults to Ctrl+B (tmux default) but is configured per-user. Felipe's configuration:

```
# ~/.tmux.conf
unbind C-b
set-option -g prefix C-s
bind-key C-s send-prefix
```

The command palette sends: `\x13` (Ctrl+S) followed by the action key.
