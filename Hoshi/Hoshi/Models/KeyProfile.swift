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

    var isShell: Bool { id == KeyProfile.shellID }
    var usesPrefix: Bool { keys.contains { $0.chord?.lowercased().contains("prefix") == true } || prefix != nil }

    /// Keys ready for the toolbar, with chord bytes encoded for this set's prefix.
    var resolvedKeys: [ToolbarButton] {
        keys.map { $0.resolved(prefix: prefix) }
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
            keys: HerdrKeyImport.keys(bindings: HerdrKeyImport.defaultBindings)
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
    /// Picks the key set for a terminal: an explicit pin wins, then the first set
    /// (in `profiles` order) whose pattern matches a word of the title, then Shell.
    static func resolve(
        title: String?,
        pinnedID: String?,
        autoSwitch: Bool,
        profiles: [KeyProfile]
    ) -> KeyProfile {
        let shell = profiles.first { $0.isShell } ?? .shell
        if let pinnedID, let pinned = profiles.first(where: { $0.id == pinnedID }) {
            return pinned
        }
        guard autoSwitch, let title, !title.isEmpty else { return shell }
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

/// Maps Herdr actions to toolbar keys, from defaults or the server's config.toml.
enum HerdrKeyImport {
    static let defaultPrefix = "ctrl+b"

    struct Action {
        let name: String
        let label: String
        let symbol: String?
    }

    /// Actions worth a toolbar key on a phone, in toolbar order.
    static let actions: [Action] = [
        Action(name: "workspace_picker", label: "Spaces", symbol: "square.grid.2x2"),
        Action(name: "goto", label: "Goto", symbol: "arrow.right.square"),
        Action(name: "previous_agent", label: "‹Agent", symbol: nil),
        Action(name: "next_agent", label: "Agent›", symbol: nil),
        Action(name: "previous_workspace", label: "‹Space", symbol: nil),
        Action(name: "next_workspace", label: "Space›", symbol: nil),
        Action(name: "previous_tab", label: "‹Tab", symbol: nil),
        Action(name: "next_tab", label: "Tab›", symbol: nil),
        Action(name: "new_tab", label: "New Tab", symbol: "plus.square"),
        Action(name: "split_vertical", label: "Split |", symbol: "rectangle.split.2x1"),
        Action(name: "split_horizontal", label: "Split —", symbol: "rectangle.split.1x2"),
        Action(name: "zoom", label: "Zoom", symbol: "arrow.up.left.and.arrow.down.right"),
        Action(name: "last_pane", label: "Last", symbol: "arrow.uturn.backward.square"),
        Action(name: "close_pane", label: "Close", symbol: "xmark.square"),
        Action(name: "toggle_sidebar", label: "Sidebar", symbol: "sidebar.left"),
        Action(name: "edit_scrollback", label: "Scroll", symbol: "scroll"),
        Action(name: "detach", label: "Detach", symbol: "eject"),
    ]

    /// Herdr 0.9 defaults for the actions above ("" = unbound).
    static let defaultBindings: [String: [String]] = [
        "workspace_picker": ["prefix+w"],
        "goto": ["prefix+g"],
        "previous_agent": [],
        "next_agent": [],
        "previous_workspace": [],
        "next_workspace": [],
        "previous_tab": ["prefix+p"],
        "next_tab": ["prefix+n"],
        "new_tab": ["prefix+c"],
        "split_vertical": ["prefix+v"],
        "split_horizontal": ["prefix+minus"],
        "zoom": ["prefix+z"],
        "last_pane": [],
        "close_pane": ["prefix+x"],
        "toggle_sidebar": ["prefix+b"],
        "edit_scrollback": ["prefix+e"],
        "detach": ["prefix+q"],
    ]

    struct Result: Equatable {
        let prefix: String
        let keys: [ToolbarButton]
        let importedActionCount: Int
    }

    /// Builds the Herdr key set from a config.toml (nil = defaults only).
    static func profileKeys(fromConfig config: String?) -> Result {
        let parsed = config.map(parseKeysSection) ?? [:]
        let prefix = parsed["prefix"]?.first.flatMap { $0.isEmpty ? nil : $0 } ?? defaultPrefix

        var bindings = defaultBindings
        var overridden = 0
        for action in actions {
            if let values = parsed[action.name] {
                bindings[action.name] = values
                overridden += 1
            }
        }
        return Result(prefix: prefix, keys: keys(bindings: bindings, prefix: prefix), importedActionCount: overridden)
    }

    static func keys(bindings: [String: [String]], prefix: String = defaultPrefix) -> [ToolbarButton] {
        var keys: [ToolbarButton] = [
            .esc,
            .custom(label: "⇧Tab", chord: "shift+tab", id: "custom-herdr-shift-tab"),
            .ctrlC,
            .custom(label: "Pfx", chord: "prefix", id: "custom-herdr-prefix"),
        ]
        for action in actions {
            // First binding that encodes; ranges and empty strings are skipped.
            guard let chord = bindings[action.name]?.first(where: {
                !$0.isEmpty && KeyChord.isValid($0, prefix: prefix)
            }) else { continue }
            keys.append(.custom(label: action.label, chord: chord, symbol: action.symbol, id: "custom-herdr-\(action.name)"))
        }
        keys += [.arrowUp, .arrowDown, .paste, .voicePrompt]
        return keys
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

    /// Shell command that prints the Herdr config, honoring XDG_CONFIG_HOME.
    static let readConfigCommand =
        "cat \"${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml\" 2>/dev/null || printf '__HERDR_NO_CONFIG__'"
    static let noConfigMarker = "__HERDR_NO_CONFIG__"
}
