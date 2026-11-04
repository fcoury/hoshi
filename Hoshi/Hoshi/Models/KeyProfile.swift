import Foundation

/// A named toolbar layout ("key set") for a kind of terminal program.
///
/// The Shell set is the user's classic toolbar and is persisted by
/// `ToolbarConfigurationService`; every other set stores its own keys, which may
/// mix built-in toolbar buttons with custom chord keys.
struct KeyProfile: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var symbol: String
    /// Words matched against the terminal title to switch to this set automatically.
    var matchPatterns: [String]
    /// Chord that `prefix` expands to inside this set's keys (e.g. `ctrl+b`).
    var prefix: String?
    var keys: [ToolbarButton]
    /// Herdr `[keys]` bindings imported from a server; nil = Herdr defaults.
    var herdrBindings: [String: [String]]? = nil
    /// Server the bindings were imported from, and when.
    var herdrBindingsSource: String? = nil
    var herdrImportedAt: Date? = nil

    var isShell: Bool { id == KeyProfile.shellID }

    /// Keys ready for the toolbar, with chord bytes encoded for this set's prefix.
    /// Herdr action keys that are unbound on the server are left out.
    var resolvedKeys: [ToolbarButton] {
        keys.compactMap { resolve($0) }
    }

    /// The key as the toolbar sends it, or nil when it is an unbound Herdr action.
    func resolve(_ key: ToolbarButton) -> ToolbarButton? {
        guard let action = key.herdrAction else { return key.resolved(prefix: prefix) }
        guard let chord = HerdrKeyImport.binding(for: action, bindings: herdrBindings, prefix: prefix) else {
            return nil
        }
        var bound = key
        bound.chord = chord
        return bound.resolved(prefix: prefix)
    }

    static let shellID = "shell"
    static let herdrID = "herdr"
    static let tmuxID = "tmux"
    static let vimID = "vim"
    static let agentID = "agent"
    static let pagerID = "pager"

    /// Automatic matching order: outer multiplexers first, then programs.
    static let builtInOrder = [herdrID, tmuxID, vimID, agentID, pagerID, shellID]
}

// MARK: - Built-in sets

extension KeyProfile {
    @MainActor
    static func builtIn(_ id: String) -> KeyProfile? {
        builtIns.first { $0.id == id }
    }

    @MainActor
    static var builtIns: [KeyProfile] {
        [herdr, tmux, vim, agent, pager, shell]
    }

    static var shell: KeyProfile {
        KeyProfile(
            id: shellID,
            name: "Shell",
            symbol: "terminal",
            matchPatterns: [],
            prefix: nil,
            keys: ToolbarButton.defaultButtons
        )
    }

    static var herdr: KeyProfile {
        KeyProfile(
            id: herdrID,
            name: "Herdr",
            symbol: "square.stack.3d.up",
            matchPatterns: ["herdr"],
            prefix: HerdrKeyImport.defaultPrefix,
            keys: HerdrKeyImport.defaultKeys()
        )
    }

    /// Seeds its prefix from the tmux shortcut settings.
    @MainActor
    static var tmux: KeyProfile {
        let prefix = KeyChord.chord(fromTmuxNotation: TmuxConfigurationService.shared.prefix) ?? "ctrl+b"
        return KeyProfile(
            id: tmuxID,
            name: "tmux",
            symbol: "rectangle.split.3x1",
            matchPatterns: ["tmux"],
            prefix: prefix,
            keys: [
                .esc, .ctrl,
                .custom(label: "Pfx", chord: "prefix", id: "custom-tmux-prefix"),
                .custom(label: "New", chord: "prefix+c", symbol: "plus.square", id: "custom-tmux-new"),
                .custom(label: "‹Win", chord: "prefix+p", id: "custom-tmux-prev"),
                .custom(label: "Win›", chord: "prefix+n", id: "custom-tmux-next"),
                .custom(label: "Split|", chord: "prefix+%", symbol: "rectangle.split.2x1", id: "custom-tmux-split-v"),
                .custom(label: "Split—", chord: "prefix+\"", symbol: "rectangle.split.1x2", id: "custom-tmux-split-h"),
                .custom(label: "Zoom", chord: "prefix+z", symbol: "arrow.up.left.and.arrow.down.right", id: "custom-tmux-zoom"),
                .custom(label: "Copy", chord: "prefix+[", symbol: "scroll", id: "custom-tmux-copy"),
                .custom(label: "Detach", chord: "prefix+d", symbol: "eject", id: "custom-tmux-detach"),
                .arrowUp, .arrowDown, .arrowLeft, .arrowRight,
                .ctrlC, .paste,
            ]
        )
    }

    static var vim: KeyProfile {
        KeyProfile(
            id: vimID,
            name: "Vim",
            symbol: "chevron.left.forwardslash.chevron.right",
            matchPatterns: ["vim", "nvim", "vi", "hx", "helix"],
            prefix: nil,
            keys: [
                .esc,
                .custom(label: ":", chord: "colon", id: "custom-vim-colon"),
                .slash,
                .custom(label: ":w", chord: ":w enter", id: "custom-vim-write"),
                .custom(label: ":q", chord: ":q enter", id: "custom-vim-quit"),
                .custom(label: "u", chord: "u", symbol: "arrow.uturn.backward", id: "custom-vim-undo"),
                .ctrlR,
                .ctrlD, .ctrlU,
                .arrowUp, .arrowDown, .arrowLeft, .arrowRight,
                .ctrl, .paste,
            ]
        )
    }

    static var agent: KeyProfile {
        KeyProfile(
            id: agentID,
            name: "Coding Agent",
            symbol: "sparkles",
            matchPatterns: [
                "claude", "codex", "opencode", "gemini", "aider", "copilot",
                "cursor-agent", "droid", "crush", "amp", "qwen", "kimi",
            ],
            prefix: nil,
            keys: [
                .esc,
                .custom(label: "⇧Tab", chord: "shift+tab", id: "custom-agent-mode"),
                .ctrlC,
                .slash,
                .at,
                .arrowUp, .arrowDown,
                .custom(label: "⌥⏎", chord: "alt+enter", symbol: "return", id: "custom-agent-newline"),
                .paste, .uploadFile, .voicePrompt,
            ]
        )
    }

    static var pager: KeyProfile {
        KeyProfile(
            id: pagerID,
            name: "Pager",
            symbol: "book",
            matchPatterns: ["less", "more", "man", "htop", "btop", "top", "journalctl"],
            prefix: nil,
            keys: [
                .custom(label: "q", chord: "q", symbol: "xmark", id: "custom-pager-quit"),
                .slash,
                .custom(label: "n", chord: "n", id: "custom-pager-next"),
                .custom(label: "N", chord: "shift+n", id: "custom-pager-prev"),
                .custom(label: "g", chord: "g", id: "custom-pager-top"),
                .custom(label: "G", chord: "shift+g", id: "custom-pager-bottom"),
                .pgUp, .pgDn,
                .custom(label: "Space", chord: "space", symbol: "space", id: "custom-pager-space"),
                .arrowUp, .arrowDown,
            ]
        )
    }
}

// MARK: - Automatic selection

enum KeyProfileResolver {
    /// Picks the key set for a terminal: an explicit pin wins, then a set implied by
    /// how the session is attached (e.g. Herdr), then the first set (in `profiles`
    /// order) whose pattern matches a word of the title, then Shell.
    static func resolve(
        title: String?,
        pinnedID: String?,
        attachedID: String? = nil,
        autoSwitch: Bool,
        profiles: [KeyProfile]
    ) -> KeyProfile {
        let shell = profiles.first { $0.isShell } ?? .shell
        if let pinnedID, let pinned = profiles.first(where: { $0.id == pinnedID }) {
            return pinned
        }
        guard autoSwitch else { return shell }
        if let attachedID, let attached = profiles.first(where: { $0.id == attachedID }) {
            return attached
        }
        guard let title, !title.isEmpty else { return shell }
        let words = titleWords(title)
        for profile in profiles where !profile.isShell {
            if profile.matchPatterns.contains(where: { matches($0, title: title, words: words) }) {
                return profile
            }
        }
        return shell
    }

    static func titleWords(_ title: String) -> Set<String> {
        let separators = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).inverted
        return Set(title.lowercased().components(separatedBy: separators).filter { !$0.isEmpty })
    }

    private static func matches(_ pattern: String, title: String, words: Set<String>) -> Bool {
        let needle = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return false }
        // Multi-word or punctuated patterns match as substrings; single words as whole words
        // so "top" doesn't fire on "desktop".
        if needle.rangeOfCharacter(from: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).inverted) != nil {
            return title.lowercased().contains(needle)
        }
        return words.contains(needle)
    }
}

// MARK: - Herdr

/// Herdr's action catalog, its default bindings, and config.toml import.
///
/// Herdr keys in a key set reference an action by name (`ToolbarButton.herdrAction`);
/// the chord is looked up at display time from the bindings imported from the
/// server (`KeyProfile.herdrBindings`), falling back to Herdr's defaults. Importing
/// therefore refreshes bindings without touching which keys the user picked.
enum HerdrKeyImport {
    static let defaultPrefix = "ctrl+b"

    struct Action: Identifiable {
        let name: String
        let label: String
        let symbol: String?
        let group: Group
        /// Herdr 0.9 defaults; empty means unbound by default.
        let defaults: [String]

        var id: String { name }
    }

    enum Group: String, CaseIterable {
        case workspaces = "Workspaces"
        case agents = "Agents"
        case tabs = "Tabs"
        case panes = "Panes"
        case app = "App"
    }

    static let catalog: [Action] = [
        // Workspaces
        Action(name: "workspace_picker", label: "Spaces", symbol: "square.grid.2x2", group: .workspaces, defaults: ["prefix+w"]),
        Action(name: "goto", label: "Goto", symbol: "arrow.right.square", group: .workspaces, defaults: ["prefix+g"]),
        Action(name: "previous_workspace", label: "‹Space", symbol: nil, group: .workspaces, defaults: []),
        Action(name: "next_workspace", label: "Space›", symbol: nil, group: .workspaces, defaults: []),
        Action(name: "new_workspace", label: "New Space", symbol: "plus.rectangle.on.rectangle", group: .workspaces, defaults: ["prefix+shift+n"]),
        Action(name: "rename_workspace", label: "Rename Space", symbol: nil, group: .workspaces, defaults: ["prefix+shift+w"]),
        Action(name: "close_workspace", label: "Close Space", symbol: nil, group: .workspaces, defaults: ["prefix+shift+d"]),
        Action(name: "new_worktree", label: "Worktree", symbol: "arrow.triangle.branch", group: .workspaces, defaults: ["prefix+shift+g"]),
        Action(name: "open_worktree", label: "Open Worktree", symbol: nil, group: .workspaces, defaults: []),
        Action(name: "remove_worktree", label: "Rm Worktree", symbol: nil, group: .workspaces, defaults: []),
        // Agents
        Action(name: "previous_agent", label: "‹Agent", symbol: nil, group: .agents, defaults: []),
        Action(name: "next_agent", label: "Agent›", symbol: nil, group: .agents, defaults: []),
        Action(name: "open_notification_target", label: "Notified", symbol: "bell.badge", group: .agents, defaults: ["prefix+o"]),
        // Tabs
        Action(name: "previous_tab", label: "‹Tab", symbol: nil, group: .tabs, defaults: ["prefix+p"]),
        Action(name: "next_tab", label: "Tab›", symbol: nil, group: .tabs, defaults: ["prefix+n"]),
        Action(name: "new_tab", label: "New Tab", symbol: "plus.square", group: .tabs, defaults: ["prefix+c"]),
        Action(name: "rename_tab", label: "Rename Tab", symbol: nil, group: .tabs, defaults: ["prefix+shift+t"]),
        Action(name: "close_tab", label: "Close Tab", symbol: nil, group: .tabs, defaults: ["prefix+shift+x"]),
        Action(name: "move_tab_previous", label: "Move ‹Tab", symbol: nil, group: .tabs, defaults: []),
        Action(name: "move_tab_next", label: "Move Tab›", symbol: nil, group: .tabs, defaults: []),
        // Panes
        Action(name: "split_vertical", label: "Split |", symbol: "rectangle.split.2x1", group: .panes, defaults: ["prefix+v"]),
        Action(name: "split_horizontal", label: "Split —", symbol: "rectangle.split.1x2", group: .panes, defaults: ["prefix+minus"]),
        Action(name: "zoom", label: "Zoom", symbol: "arrow.up.left.and.arrow.down.right", group: .panes, defaults: ["prefix+z"]),
        Action(name: "close_pane", label: "Close", symbol: "xmark.square", group: .panes, defaults: ["prefix+x"]),
        Action(name: "last_pane", label: "Last", symbol: "arrow.uturn.backward.square", group: .panes, defaults: []),
        Action(name: "focus_pane_left", label: "Pane ←", symbol: nil, group: .panes, defaults: ["prefix+h"]),
        Action(name: "focus_pane_down", label: "Pane ↓", symbol: nil, group: .panes, defaults: ["prefix+j"]),
        Action(name: "focus_pane_up", label: "Pane ↑", symbol: nil, group: .panes, defaults: ["prefix+k"]),
        Action(name: "focus_pane_right", label: "Pane →", symbol: nil, group: .panes, defaults: ["prefix+l"]),
        Action(name: "cycle_pane_next", label: "Pane›", symbol: nil, group: .panes, defaults: ["prefix+tab"]),
        Action(name: "cycle_pane_previous", label: "‹Pane", symbol: nil, group: .panes, defaults: ["prefix+shift+tab"]),
        Action(name: "swap_pane_left", label: "Swap ←", symbol: nil, group: .panes, defaults: ["prefix+shift+h"]),
        Action(name: "swap_pane_down", label: "Swap ↓", symbol: nil, group: .panes, defaults: ["prefix+shift+j"]),
        Action(name: "swap_pane_up", label: "Swap ↑", symbol: nil, group: .panes, defaults: ["prefix+shift+k"]),
        Action(name: "swap_pane_right", label: "Swap →", symbol: nil, group: .panes, defaults: ["prefix+shift+l"]),
        Action(name: "resize_mode", label: "Resize", symbol: "arrow.up.and.down.and.arrow.left.and.right", group: .panes, defaults: ["prefix+r"]),
        Action(name: "resize_pane_left", label: "Size ←", symbol: nil, group: .panes, defaults: []),
        Action(name: "resize_pane_down", label: "Size ↓", symbol: nil, group: .panes, defaults: []),
        Action(name: "resize_pane_up", label: "Size ↑", symbol: nil, group: .panes, defaults: []),
        Action(name: "resize_pane_right", label: "Size →", symbol: nil, group: .panes, defaults: []),
        Action(name: "rename_pane", label: "Rename Pane", symbol: nil, group: .panes, defaults: ["prefix+shift+p"]),
        Action(name: "copy_mode", label: "Copy", symbol: "doc.on.doc", group: .panes, defaults: ["prefix+["]),
        Action(name: "edit_scrollback", label: "Scroll", symbol: "scroll", group: .panes, defaults: ["prefix+e"]),
        Action(name: "clear_pane", label: "Clear", symbol: "eraser", group: .panes, defaults: []),
        // App
        Action(name: "toggle_sidebar", label: "Sidebar", symbol: "sidebar.left", group: .app, defaults: ["prefix+b"]),
        Action(name: "help", label: "Help", symbol: "questionmark.circle", group: .app, defaults: ["prefix+?"]),
        Action(name: "settings", label: "Settings", symbol: "gearshape", group: .app, defaults: ["prefix+s"]),
        Action(name: "reload_config", label: "Reload", symbol: "arrow.clockwise", group: .app, defaults: ["prefix+shift+r"]),
        Action(name: "detach", label: "Detach", symbol: "eject", group: .app, defaults: ["prefix+q"]),
    ]

    /// Legacy config names that Herdr still accepts.
    private static let aliases: [String: String] = ["zoom": "fullscreen"]

    /// Actions on a fresh Herdr key set, in toolbar order.
    static let defaultSelection = [
        "workspace_picker", "goto", "previous_agent", "next_agent",
        "previous_workspace", "next_workspace", "previous_tab", "next_tab", "new_tab",
        "split_vertical", "split_horizontal", "zoom", "last_pane", "close_pane",
        "toggle_sidebar", "edit_scrollback", "detach",
    ]

    static func action(named name: String) -> Action? {
        catalog.first { $0.name == name }
    }

    static func button(for action: Action) -> ToolbarButton {
        ToolbarButton(
            id: "herdr-\(action.name)",
            label: action.label,
            bytes: [],
            category: .herdr,
            symbol: action.symbol,
            herdrAction: action.name
        )
    }

    static func defaultKeys() -> [ToolbarButton] {
        [
            .esc,
            .custom(label: "⇧Tab", chord: "shift+tab", id: "custom-herdr-shift-tab"),
            .ctrlC,
            .custom(label: "Pfx", chord: "prefix", id: "custom-herdr-prefix"),
        ]
        + defaultSelection.compactMap(action(named:)).map(button(for:))
        + [.arrowUp, .arrowDown, .paste, .voicePrompt]
    }

    /// The chord an action sends: the first binding that encodes, from imported
    /// bindings when the server configures the action, otherwise Herdr's default.
    /// nil means the action is unbound (explicitly `""`, unset, or only ranges).
    static func binding(for actionName: String, bindings: [String: [String]]?, prefix: String?) -> String? {
        let configured = bindings?[actionName] ?? aliases[actionName].flatMap { bindings?[$0] }
        let candidates = configured ?? action(named: actionName)?.defaults ?? []
        return candidates.first { !$0.isEmpty && KeyChord.isValid($0, prefix: prefix) }
    }

    struct Result: Equatable {
        let prefix: String
        /// Every binding in `[keys]` except the prefix.
        let bindings: [String: [String]]
        /// Catalog actions the config sets explicitly.
        let configuredActionCount: Int
    }

    /// Reads bindings from a config.toml (nil = server has none → Herdr defaults).
    static func importConfig(_ config: String?) -> Result {
        var parsed = config.map(parseKeysSection) ?? [:]
        let prefix = parsed.removeValue(forKey: "prefix")?.first.flatMap { $0.isEmpty ? nil : $0 } ?? defaultPrefix
        let configured = catalog.filter { action in
            parsed[action.name] != nil || aliases[action.name].map { parsed[$0] != nil } == true
        }.count
        return Result(prefix: prefix, bindings: parsed, configuredActionCount: configured)
    }

    /// Converts Herdr keys saved by earlier builds (copied chords) into action references.
    static func migrateLegacyKeys(_ keys: [ToolbarButton]) -> [ToolbarButton] {
        keys.map { key in
            guard key.herdrAction == nil,
                  key.id.hasPrefix("custom-herdr-"),
                  let action = action(named: String(key.id.dropFirst("custom-herdr-".count))) else {
                return key
            }
            return button(for: action)
        }
    }

    /// Minimal TOML reader for `[keys]`: `name = "x"` or `name = ["a", "b"]`.
    static func parseKeysSection(_ toml: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var inKeys = false
        var pendingName: String?
        var pendingValue = ""

        func commit(_ name: String, _ raw: String) {
            result[name] = quotedStrings(in: raw)
        }

        for rawLine in toml.components(separatedBy: .newlines) {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)

            if let name = pendingName {
                pendingValue += " " + line
                if line.contains("]") {
                    commit(name, pendingValue)
                    pendingName = nil
                    pendingValue = ""
                }
                continue
            }

            guard !line.isEmpty else { continue }
            if line.hasPrefix("[") {
                inKeys = line == "[keys]"
                continue
            }
            guard inKeys, let equals = line.firstIndex(of: "=") else { continue }

            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("["), !value.contains("]") {
                pendingName = name
                pendingValue = value
            } else {
                commit(name, value)
            }
        }
        return result
    }

    private static func quotedStrings(in raw: String) -> [String] {
        var values: [String] = []
        var current: String?
        var escaped = false
        for character in raw {
            if var text = current {
                if escaped {
                    text.append(character)
                    escaped = false
                    current = text
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    values.append(text)
                    current = nil
                } else {
                    text.append(character)
                    current = text
                }
            } else if character == "\"" {
                current = ""
            }
        }
        return values
    }

    /// Drops a `#` comment that is not inside a quoted string.
    private static func stripComment(_ line: String) -> String {
        var inString = false
        var output = ""
        for character in line {
            if character == "\"" { inString.toggle() }
            if character == "#", !inString { break }
            output.append(character)
        }
        return output
    }

    /// Prints the Herdr config, honoring XDG_CONFIG_HOME. Wrapped in `sh -c` because
    /// the login shell may be fish (or another non-POSIX shell), which rejects
    /// `${VAR:-default}`; the script never fails, so a missing file isn't an error.
    static let readConfigCommand =
        "sh -c 'cat \"${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml\" 2>/dev/null || printf __HERDR_NO_CONFIG__'"
    static let noConfigMarker = "__HERDR_NO_CONFIG__"
}
