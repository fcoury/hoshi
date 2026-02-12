# PRD: Hoshi (星) — Mobile Terminal for AI Agent Monitoring

**Author:** AI-generated via `/prd` skill
**Date:** 2026-02-11
**Status:** Draft

---

## 1. Problem Statement & Business Impact

Developers running AI coding agents (Claude Code, Codex, Cursor, etc.) on remote servers need a reliable way to monitor, approve prompts, and interact with those agents from their iPhone. Existing iOS terminal apps are either bloated general-purpose SSH clients (Termius) or have UX friction that gets in the way of quick terminal access (Moshi's keyboard toolbar discoverability, connection management). There is no open-source iOS terminal app purpose-built for this workflow.

**Business impact:** This is a personal-use tool. Success means the developer (fcoury) can reliably monitor AI agents from his phone without fighting the app's UX. Secondary impact: an open-source reference implementation for a modern SwiftUI terminal app.

---

## 2. Goals & Success Metrics

| Goal | Metric | Target | How to Measure |
|------|--------|--------|----------------|
| Reliable remote access | Connection success rate | 95%+ on first attempt | Manual testing across WiFi/cellular |
| Fast tmux workflow | Time from app launch to tmux session | < 5 seconds | Stopwatch from tap to interactive terminal |
| Usable keyboard | All common terminal keys accessible without hunting | 0 hidden gestures needed for core keys | All toolbar buttons visible or in customized layout |
| Daily driver quality | App used as primary mobile terminal | Replaces Moshi within 1 week of v1 | Self-reported usage |

---

## 3. User Stories

### US-001: SSH Connection

**As a** developer, **I want** to connect to a remote server via SSH, **so that** I can access my terminal remotely.

**Acceptance Criteria:**
- [ ] User can add a server with hostname, port, and username
- [ ] App supports password authentication
- [ ] App supports SSH key authentication (Ed25519, RSA)
- [ ] App can generate and store SSH key pairs in the iOS Keychain
- [ ] Connection establishes and presents an interactive terminal session
- [ ] Connection errors display a clear, actionable error message

**Priority:** 1
**Complexity:** L

---

### US-002: Mosh Connection

**As a** developer, **I want** to connect to a remote server via Mosh, **so that** my session survives network switches, sleep, and poor connectivity.

**Acceptance Criteria:**
- [ ] User can toggle Mosh on/off per server connection
- [ ] Mosh connection uses UDP and syncs terminal state on wake
- [ ] Session resumes without manual reconnection after device sleep or network change
- [ ] If mosh-server is not found on the remote host, the app offers to install it via SSH (apt/brew/yum)
- [ ] Falls back gracefully if mosh-server install is declined or fails

**Priority:** 1
**Complexity:** XL

---

### US-003: tmux Session Auto-Detection

**As a** developer, **I want** the app to detect my existing tmux sessions on connection, **so that** I can quickly attach to the right one.

**Acceptance Criteria:**
- [ ] On every connection, the app runs `tmux list-sessions` and parses the output
- [ ] A session picker UI appears showing session name, window count, and attached status
- [ ] User can tap a session to attach to it
- [ ] User can choose "New session" to create a fresh tmux session
- [ ] User can choose "Skip" to go directly to the shell without tmux
- [ ] If no tmux sessions exist, the picker shows "No sessions found" with options to create one or skip

**Priority:** 1
**Complexity:** M

---

### US-004: Terminal Emulation

**As a** developer, **I want** a functional terminal emulator that renders correctly, **so that** I can read and interact with terminal output including TUI applications.

**Acceptance Criteria:**
- [ ] Terminal supports VT100/xterm-256color escape sequences
- [ ] Text renders in a monospace font with correct character grid alignment
- [ ] Terminal supports scrollback buffer (minimum 10,000 lines)
- [ ] Terminal handles ANSI color codes (16 colors + 256-color mode)
- [ ] Copy/paste works via long-press gesture and iOS share sheet
- [ ] Pinch-to-zoom adjusts font size
- [ ] Terminal correctly renders box-drawing characters (used by tmux pane borders, TUI apps)

**Priority:** 1
**Complexity:** XL

---

### US-005: Customizable Keyboard Toolbar

**As a** developer, **I want** a fully customizable keyboard toolbar with all essential terminal keys visible, **so that** I never have to hunt for a key.

**Acceptance Criteria:**
- [ ] A toolbar row appears above the iOS keyboard with terminal-specific keys
- [ ] Default buttons include: Esc, Ctrl, Tab, arrow keys (all four), `/`, `-`, `|`, Ctrl+C
- [ ] User can enter an edit mode to add, remove, and drag-to-reorder toolbar buttons
- [ ] Available button palette includes: all modifier keys, F1-F12, common symbols, tmux prefix (Ctrl+B)
- [ ] Toolbar configuration persists across app launches
- [ ] Toolbar is scrollable if more buttons are added than fit on screen

**Priority:** 2
**Complexity:** L

---

### US-006: Server Connection Management

**As a** developer, **I want** to save and manage multiple server connections, **so that** I can quickly connect to any of my machines.

**Acceptance Criteria:**
- [ ] User can save a server with: name, hostname, port, username, auth method, and Mosh toggle
- [ ] Server list shows all saved connections on the home screen
- [ ] User can edit or delete saved servers
- [ ] Each connection to a server (with or without a specific tmux session) is preserved as a distinct entry
- [ ] Last-used connections appear at the top of the list

**Priority:** 2
**Complexity:** M

---

### US-007: Dark-Only Theme

**As a** developer, **I want** the app to use a dark terminal theme, **so that** it looks good and is easy on the eyes.

**Acceptance Criteria:**
- [ ] App uses a dark color scheme throughout (no light mode)
- [ ] Terminal uses a curated dark theme (e.g., Nord or Dracula palette)
- [ ] Status bar, navigation, and modals all use dark backgrounds
- [ ] Text contrast meets WCAG AA standards for readability

**Priority:** 3
**Complexity:** S

---

### US-008: Session Persistence

**As a** developer, **I want** my terminal sessions to persist when I switch apps or lock my phone, **so that** I don't lose my place.

**Acceptance Criteria:**
- [ ] Switching to another app and back preserves the terminal session state
- [ ] Mosh sessions resume automatically after device sleep
- [ ] SSH sessions attempt reconnection if the TCP connection drops
- [ ] A visual indicator shows connection status (connected, reconnecting, disconnected)

**Priority:** 2
**Complexity:** M

---

### US-009: Connection Quick-Launch

**As a** developer, **I want** to quickly reconnect to my most-used server+tmux combination, **so that** I spend minimal time navigating the app.

**Acceptance Criteria:**
- [ ] Home screen shows recent connections with server name and tmux session name
- [ ] Tapping a recent connection initiates the connection immediately
- [ ] If the previous tmux session no longer exists, the app falls back to the tmux picker

**Priority:** 3
**Complexity:** S

---

## 4. Functional Requirements

| ID | Requirement | Maps to |
|----|-------------|---------|
| FR-1 | Implement SSH client using a Swift SSH library (e.g., NMSSH, Shout, or libssh2 binding) | US-001 |
| FR-2 | Implement Mosh client protocol (UDP-based state synchronization) | US-002 |
| FR-3 | SSH key generation and Keychain storage using Security framework | US-001 |
| FR-4 | tmux session detection via parsing `tmux list-sessions` output over SSH | US-003 |
| FR-5 | Terminal emulator rendering engine (research: SwiftTerm or custom CoreText) | US-004 |
| FR-6 | Keyboard accessory view with UIKit InputAccessoryView or SwiftUI overlay | US-005 |
| FR-7 | Drag-to-reorder toolbar using `onDrag`/`onDrop` or `EditMode` with `onMove` | US-005 |
| FR-8 | Persistent server storage using SwiftData or Core Data | US-006 |
| FR-9 | App lifecycle handling for session persistence (UIScene delegate) | US-008 |
| FR-10 | Mosh-server detection and SSH-based installation offer | US-002 |
| FR-11 | Connection status indicator overlay on terminal view | US-008 |
| FR-12 | Recent connections list with quick-launch capability | US-009 |

---

## 5. Non-Goals / Out of Scope

- **Light mode / multiple themes** — Dark-only for v1. Multiple themes are a v1.1 enhancement.
- **Push notifications / webhooks** — Valuable but not MVP. Planned for v1.1.
- **Voice-to-terminal (Whisper)** — Planned for v1.1.
- **Face ID / biometric unlock for SSH keys** — Planned for v1.1.
- **Tailscale integration** — v2.
- **Clipboard sync** — v2.
- **iPad/macOS optimization** — iOS-first. iPad may work via compatibility but is not explicitly designed for.
- **File transfer / SFTP** — Out of scope.
- **Image editor / screenshot upload** — Out of scope.
- **General-purpose SSH client features** — No port forwarding, tunnels, or jump hosts in v1.
- **Android** — Not planned.

---

## 6. Technical Considerations

### Architecture

SwiftUI app targeting iOS 17+. The app follows a layered architecture:

```
┌─────────────────────────────────────────┐
│  SwiftUI Views (Terminal, Picker, etc.) │
├─────────────────────────────────────────┤
│  ViewModels (connection, session state) │
├─────────────────────────────────────────┤
│  Services (SSH, Mosh, tmux detection)   │
├─────────────────────────────────────────┤
│  Core (terminal emulator, key storage)  │
└─────────────────────────────────────────┘
```

### Key Technology Decisions (Require Research)

1. **Terminal emulator**: SwiftTerm (open-source, mature) vs. custom CoreText renderer. Agent should evaluate both and recommend.
2. **SSH library**: NMSSH, Shout, or direct libssh2 wrapper. Agent should evaluate Swift ecosystem options.
3. **Mosh protocol**: May need to compile mosh-client C++ code for iOS or use a Swift wrapper. This is the highest-risk technical decision.

### Data Model

Server connections stored via SwiftData:

```
Server {
  id: UUID
  name: String
  hostname: String
  port: Int (default 22)
  username: String
  authMethod: enum (password, key)
  useMosh: Bool
  lastConnected: Date?
  lastTmuxSession: String?
}

KeyboardToolbarConfig {
  id: UUID
  buttons: [ToolbarButton] (ordered)
}

ToolbarButton {
  id: UUID
  type: enum (esc, ctrl, tab, arrowUp, arrowDown, arrowLeft, arrowRight, ...)
  label: String
  keySequence: String
}
```

### Dependencies

- **SSH**: libssh2 (via SPM wrapper) or NMSSH
- **Mosh**: mosh-client (C/C++ compiled for iOS)
- **Terminal**: SwiftTerm or custom
- **Storage**: SwiftData (iOS 17+)
- **Security**: Apple Security framework (Keychain)

---

## 7. Boundaries

### Always Do
- Write tests for all connection and tmux detection logic
- Follow Swift/SwiftUI conventions and Apple HIG where applicable
- Use Keychain for all credential storage — never store passwords or keys in UserDefaults
- Handle connection errors gracefully with user-facing messages
- Use async/await for all network operations

### Ask First
- Before choosing the terminal emulator library (SwiftTerm vs. custom)
- Before choosing the SSH library
- Before making any Mosh protocol implementation decisions
- Before adding any third-party dependencies via SPM
- Before modifying the data model schema after initial implementation

### Never Change
- The app must remain dark-only — do not add light mode support
- Do not add subscription/payment infrastructure
- Do not add telemetry, analytics, or crash reporting SDKs
- Do not store credentials outside of the iOS Keychain

---

## 8. Task Breakdown Hints

Suggested implementation order. The agent should follow this sequence unless there's a good reason to deviate.

| Order | Task | Depends On | Complexity | Notes |
|-------|------|------------|------------|-------|
| 1 | Research & select terminal emulator library | — | S | Evaluate SwiftTerm, hterm, custom. Document recommendation. |
| 2 | Research & select SSH library | — | S | Evaluate NMSSH, Shout, libssh2. Document recommendation. |
| 3 | Research Mosh client feasibility for iOS | — | M | Can mosh-client C++ be compiled for iOS? Any Swift wrappers? |
| 4 | Set up Xcode project with SwiftUI, SwiftData | — | S | iOS 17+ target, dark-only appearance |
| 5 | Implement SSH connection service | Task 2 | L | Connect, authenticate, get interactive shell |
| 6 | Implement terminal emulator view | Task 1 | XL | Render terminal output, handle input, scrollback |
| 7 | Integrate SSH with terminal view | Tasks 5, 6 | M | Pipe SSH channel I/O to terminal emulator |
| 8 | Implement server management (CRUD) | Task 4 | M | SwiftData models, list view, add/edit forms |
| 9 | Implement tmux session detection & picker | Task 7 | M | Parse `tmux list-sessions`, show picker UI |
| 10 | Implement keyboard toolbar | Task 6 | L | Custom InputAccessoryView, drag-to-reorder, persistence |
| 11 | Implement Mosh protocol | Task 3, 7 | XL | Highest risk. May need C++ bridging. |
| 12 | Implement mosh-server install offer | Tasks 5, 11 | S | Detect missing mosh-server, offer apt/brew/yum install |
| 13 | Implement session persistence | Tasks 7, 11 | M | Handle app lifecycle, reconnection logic |
| 14 | Implement recent connections & quick-launch | Tasks 8, 9 | S | Track last-used, show on home screen |
| 15 | Apply dark theme polish | All | S | Final pass on colors, contrast, typography |
| 16 | End-to-end testing on real servers | All | M | Test SSH + Mosh + tmux workflow on real hardware |

---

## 9. Open Questions

- [ ] Which terminal emulator library is best suited for iOS? (SwiftTerm is the leading candidate but needs evaluation)
- [ ] Is there a pre-built Mosh client library for iOS, or does mosh-client need to be compiled from C++ source?
- [ ] What SSH library provides the best combination of Swift API ergonomics and protocol completeness?
- [ ] Should the app use a `PTY` (pseudo-terminal) locally, or pipe directly to the SSH channel?
- [ ] What is the minimum iOS version worth supporting? (17.0 for SwiftData, or 16.0 with Core Data fallback?)
- [ ] Should the app support SSH agent forwarding in v1?
- [ ] What license? (MIT, Apache 2.0, GPL?)

---

## Post-v1 Roadmap

### v1.1
- Push notifications via webhook API
- Terminal theme picker (Nord, Dracula, Solarized, etc.)
- Voice-to-terminal using on-device Whisper (CoreML)
- Face ID / Touch ID unlock for SSH keys
- Multiple keyboard toolbar profiles

### v2
- Tailscale integration (direct connection to Tailscale nodes)
- Clipboard sync between iOS and remote server
- iPad-optimized layout
- File upload via SSH/SCP

---

*This PRD pairs with `prd.json` for machine-readable agent execution. The PRD is the "what", `CLAUDE.md` is the "how".*
