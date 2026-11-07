import Foundation

/// Encodes human-readable key chords into terminal input bytes.
///
/// The notation follows Herdr's config.toml so imported bindings can be used
/// verbatim. A binding is a space-separated sequence of tokens:
///
/// - Chords: `ctrl+s`, `alt+up`, `shift+tab`, `prefix+shift+b`, `prefix+minus`
/// - Named keys: `esc`, `enter`, `tab`, `space`, `backspace`, `up`, `pgup`, `f5`, …
/// - Literal text: `:w` (any token that is not a chord or named key)
/// - Quoted text: `"ls -la"` is typed exactly as written, spaces and key names included
///
/// `prefix` expands to the owning key set's prefix chord (for example `ctrl+b`).
enum KeyChord {
    enum EncodingError: Error, Equatable, LocalizedError {
        case empty
        case missingPrefix
        case unknownKey(String)
        case unsupportedRange(String)

        var errorDescription: String? {
            switch self {
            case .empty: "Enter a key or chord."
            case .missingPrefix: "This key set has no prefix configured."
            case .unknownKey(let key): "Unknown key “\(key)”."
            case .unsupportedRange(let token): "Ranges like “\(token)” can't be a single key."
            }
        }
    }

    static func encode(_ binding: String, prefix: String? = nil) throws -> [UInt8] {
        let tokens = tokens(binding)
        guard !tokens.isEmpty else { throw EncodingError.empty }

        var bytes: [UInt8] = []
        for token in tokens {
            switch token {
            case .key(let key): bytes += try encodeToken(key, prefix: prefix, depth: 0)
            case .text(let text): bytes += Array(text.utf8)
            }
        }
        return bytes
    }

    enum Token: Equatable {
        /// A chord, named key or bare word.
        case key(String)
        /// Quoted text, typed as written.
        case text(String)
    }

    /// Splits a binding on whitespace, keeping `"quoted text"` (straight or curly quotes,
    /// as iOS Smart Punctuation types them) as one token. A quote that opens a token but
    /// is never closed is an ordinary character, so a lone `"` still types a quote.
    static func tokens(_ binding: String) -> [Token] {
        let quotes: Set<Character> = ["\"", "\u{201C}", "\u{201D}"]
        let chars = Array(binding)
        var tokens: [Token] = []
        var i = 0
        while i < chars.count {
            if chars[i].isWhitespace {
                i += 1
                continue
            }
            if quotes.contains(chars[i]),
               let close = chars[(i + 1)...].firstIndex(where: { quotes.contains($0) }) {
                let text = String(chars[(i + 1)..<close])
                if !text.isEmpty { tokens.append(.text(text)) }
                i = close + 1
                continue
            }
            var end = i
            while end < chars.count, !chars[end].isWhitespace { end += 1 }
            tokens.append(.key(String(chars[i..<end])))
            i = end
        }
        return tokens
    }

    /// True when the binding can be encoded with the given prefix.
    static func isValid(_ binding: String, prefix: String? = nil) -> Bool {
        (try? encode(binding, prefix: prefix)) != nil
    }

    /// Converts tmux-style prefix notation (`^B`, `C-a`) to chord notation.
    static func chord(fromTmuxNotation notation: String) -> String? {
        let trimmed = notation.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("^"), trimmed.count == 2 {
            return "ctrl+\(trimmed.dropFirst().lowercased())"
        }
        if trimmed.lowercased().hasPrefix("c-"), trimmed.count == 3 {
            return "ctrl+\(trimmed.dropFirst(2).lowercased())"
        }
        return nil
    }

    // MARK: - Tokens

    private static func encodeToken(_ token: String, prefix: String?, depth: Int) throws -> [UInt8] {
        if token.contains("..") {
            throw EncodingError.unsupportedRange(token)
        }

        let parts = splitChord(token)
        if parts.count == 1 {
            let only = parts[0]
            if only.lowercased() == "prefix" {
                return try prefixBytes(prefix, depth: depth)
            }
            if let named = namedKey(only.lowercased()) {
                return named.bytes(modifiers: [])
            }
            // A literal: single characters or free text like ":w".
            return Array(only.utf8)
        }

        var modifiers: Set<Modifier> = []
        var leading: [UInt8] = []
        for part in parts.dropLast() {
            let lowered = part.lowercased()
            if lowered == "prefix" {
                leading += try prefixBytes(prefix, depth: depth)
            } else if let modifier = Modifier(rawValue: canonicalModifier(lowered)) {
                modifiers.insert(modifier)
            } else {
                throw EncodingError.unknownKey(part)
            }
        }

        guard let keyPart = parts.last, !keyPart.isEmpty else {
            throw EncodingError.unknownKey(token)
        }
        return leading + (try encodeKey(keyPart, modifiers: modifiers))
    }

    /// Splits on `+` while keeping a trailing literal `+` key (`ctrl++`).
    private static func splitChord(_ token: String) -> [String] {
        guard token.count > 1 else { return [token] }
        var parts = token.components(separatedBy: "+")
        if token.hasSuffix("++") {
            parts.removeLast(2)
            parts.append("+")
        } else if token.hasSuffix("+") {
            return [token]
        }
        return parts.filter { !$0.isEmpty }
    }

    private static func prefixBytes(_ prefix: String?, depth: Int) throws -> [UInt8] {
        guard let prefix, !prefix.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw EncodingError.missingPrefix
        }
        // A prefix that refers to itself would recurse forever.
        guard depth == 0 else { throw EncodingError.missingPrefix }
        let tokens = prefix.split(whereSeparator: \.isWhitespace).map(String.init)
        return try tokens.flatMap { try encodeToken($0, prefix: nil, depth: depth + 1) }
    }

    private enum Modifier: String {
        case ctrl, alt, shift
    }

    private static func canonicalModifier(_ name: String) -> String {
        switch name {
        case "control", "c": "ctrl"
        case "opt", "option", "meta", "m": "alt"
        case "s": "shift"
        default: name
        }
    }

    private static func encodeKey(_ key: String, modifiers: Set<Modifier>) throws -> [UInt8] {
        if let named = namedKey(key.lowercased()) {
            return named.bytes(modifiers: modifiers)
        }

        guard key.count == 1, let scalar = key.unicodeScalars.first else {
            throw EncodingError.unknownKey(key)
        }

        var character = Character(scalar)
        if modifiers.contains(.shift), character.isLetter {
            character = Character(character.uppercased())
        }

        var bytes: [UInt8]
        if modifiers.contains(.ctrl) {
            guard let control = controlByte(for: character) else {
                throw EncodingError.unknownKey("ctrl+\(key)")
            }
            bytes = [control]
        } else {
            bytes = Array(String(character).utf8)
        }

        if modifiers.contains(.alt) {
            bytes.insert(0x1B, at: 0)
        }
        return bytes
    }

    private static func controlByte(for character: Character) -> UInt8? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case 0x61...0x7A: return ascii - 0x60          // a-z
        case 0x41...0x5A: return ascii - 0x40          // A-Z
        case 0x40: return 0x00                           // @
        case 0x5B: return 0x1B                           // [
        case 0x5C: return 0x1C                           // \
        case 0x5D: return 0x1D                           // ]
        case 0x5E: return 0x1E                           // ^
        case 0x5F: return 0x1F                           // _
        case 0x3F: return 0x7F                           // ?
        case 0x20: return 0x00                           // space
        default: return nil
        }
    }

    // MARK: - Named keys

    private enum NamedKey {
        case byte(UInt8)
        case text(String)
        /// CSI cursor key with final byte (A/B/C/D/H/F).
        case cursor(Character)
        /// CSI `n ~` key (PgUp = 5, F5 = 15, …).
        case tilde(Int)
        /// SS3 function key F1–F4 (P/Q/R/S).
        case ss3(Character)
        case shiftTab

        func bytes(modifiers: Set<Modifier>) -> [UInt8] {
            let code = KeyChord.xtermModifierCode(modifiers)
            switch self {
            case .byte(let value):
                if self.isTab, modifiers.contains(.shift) { return Array("\u{1B}[Z".utf8) }
                var bytes = [value]
                if modifiers.contains(.ctrl), value == 0x20 { bytes = [0x00] }
                return modifiers.contains(.alt) ? [0x1B] + bytes : bytes
            case .text(let text):
                let bytes = Array(text.utf8)
                return modifiers.contains(.alt) ? [0x1B] + bytes : bytes
            case .cursor(let final):
                if code == 1 { return Array("\u{1B}[\(final)".utf8) }
                return Array("\u{1B}[1;\(code)\(final)".utf8)
            case .tilde(let number):
                if code == 1 { return Array("\u{1B}[\(number)~".utf8) }
                return Array("\u{1B}[\(number);\(code)~".utf8)
            case .ss3(let final):
                if code == 1 { return Array("\u{1B}O\(final)".utf8) }
                return Array("\u{1B}[1;\(code)\(final)".utf8)
            case .shiftTab:
                return Array("\u{1B}[Z".utf8)
            }
        }

        private var isTab: Bool {
            if case .byte(0x09) = self { return true }
            return false
        }
    }

    private static func xtermModifierCode(_ modifiers: Set<Modifier>) -> Int {
        var code = 1
        if modifiers.contains(.shift) { code += 1 }
        if modifiers.contains(.alt) { code += 2 }
        if modifiers.contains(.ctrl) { code += 4 }
        return code
    }

    private static func namedKey(_ name: String) -> NamedKey? {
        switch name {
        case "esc", "escape": .byte(0x1B)
        case "enter", "return", "cr": .byte(0x0D)
        case "tab": .byte(0x09)
        case "backtab": .shiftTab
        case "space": .byte(0x20)
        case "backspace", "bs": .byte(0x7F)
        case "up": .cursor("A")
        case "down": .cursor("B")
        case "right": .cursor("C")
        case "left": .cursor("D")
        case "home": .cursor("H")
        case "end": .cursor("F")
        case "insert", "ins": .tilde(2)
        case "delete", "del": .tilde(3)
        case "pgup", "pageup": .tilde(5)
        case "pgdn", "pgdown", "pagedown": .tilde(6)
        case "f1": .ss3("P")
        case "f2": .ss3("Q")
        case "f3": .ss3("R")
        case "f4": .ss3("S")
        case "f5": .tilde(15)
        case "f6": .tilde(17)
        case "f7": .tilde(18)
        case "f8": .tilde(19)
        case "f9": .tilde(20)
        case "f10": .tilde(21)
        case "f11": .tilde(23)
        case "f12": .tilde(24)
        case "minus", "dash": .text("-")
        case "plus": .text("+")
        case "comma": .text(",")
        case "period", "dot": .text(".")
        case "semicolon": .text(";")
        case "colon": .text(":")
        case "slash": .text("/")
        case "backslash": .text("\\")
        case "pipe": .text("|")
        case "equal", "equals": .text("=")
        case "quote": .text("'")
        case "doublequote": .text("\"")
        case "backtick", "grave": .text("`")
        case "tilde": .text("~")
        case "lbracket": .text("[")
        case "rbracket": .text("]")
        case "lbrace": .text("{")
        case "rbrace": .text("}")
        case "question": .text("?")
        default: nil
        }
    }

    /// Compact, readable rendering of a binding for previews (e.g. `^S d`).
    static func displayString(_ binding: String) -> String {
        tokens(binding).map { token -> String in
            let key: String
            switch token {
            case .text(let text): return "\u{201C}\(text)\u{201D}"
            case .key(let word): key = word
            }
            let parts = splitChord(key)
            guard parts.count > 1 else { return key }
            var output = ""
            for part in parts.dropLast() {
                switch canonicalModifier(part.lowercased()) {
                case "ctrl": output += "⌃"
                case "alt": output += "⌥"
                case "shift": output += "⇧"
                case "prefix": output += "Pfx "
                default: output += part
                }
            }
            return output + (parts.last ?? "")
        }
        .joined(separator: " ")
    }
}
