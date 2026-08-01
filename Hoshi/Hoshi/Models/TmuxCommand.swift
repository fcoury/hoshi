import Foundation

enum TerminalKeySequenceError: LocalizedError, Equatable {
    case empty
    case incompleteEscape
    case invalidEscape(String)
    case invalidControlCharacter(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            "Enter a key sequence."
        case .incompleteEscape:
            "Finish the escape sequence."
        case .invalidEscape(let value):
            "Invalid escape sequence: \(value)."
        case .invalidControlCharacter(let value):
            "Invalid control character: \(value)."
        }
    }
}

/// Converts readable terminal notation into the exact bytes sent to a remote PTY.
enum TerminalKeySequence {
    static func parse(_ notation: String) throws -> [UInt8] {
        guard !notation.isEmpty else { throw TerminalKeySequenceError.empty }

        let scalars = Array(notation.unicodeScalars)
        var bytes: [UInt8] = []
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]

            if scalar == "^" {
                guard index + 1 < scalars.count else {
                    throw TerminalKeySequenceError.invalidControlCharacter("^")
                }

                let character = scalars[index + 1]
                if character == "?" {
                    bytes.append(0x7F)
                } else if character.value >= 0x40, character.value <= 0x7F {
                    bytes.append(UInt8(character.value) & 0x1F)
                } else {
                    throw TerminalKeySequenceError.invalidControlCharacter("^\(character)")
                }
                index += 2
                continue
            }

            if scalar == "\\" {
                guard index + 1 < scalars.count else {
                    throw TerminalKeySequenceError.incompleteEscape
                }

                let escaped = scalars[index + 1]
                switch escaped {
                case "e", "E": bytes.append(0x1B)
                case "n": bytes.append(0x0A)
                case "r": bytes.append(0x0D)
                case "t": bytes.append(0x09)
                case "0": bytes.append(0x00)
                case "\\": bytes.append(0x5C)
                case "^": bytes.append(0x5E)
                case "x":
                    guard index + 3 < scalars.count else {
                        throw TerminalKeySequenceError.incompleteEscape
                    }
                    let value = String(scalars[index + 2]) + String(scalars[index + 3])
                    guard let byte = UInt8(value, radix: 16) else {
                        throw TerminalKeySequenceError.invalidEscape("\\x\(value)")
                    }
                    bytes.append(byte)
                    index += 2
                default:
                    throw TerminalKeySequenceError.invalidEscape("\\\(escaped)")
                }
                index += 2
                continue
            }

            bytes.append(contentsOf: String(scalar).utf8)
            index += 1
        }

        return bytes
    }
}

struct TmuxCommand: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var detail: String
    var sequence: String
    var sendsPrefix: Bool
    var systemImage: String

    init(
        id: String = UUID().uuidString,
        title: String,
        detail: String = "",
        sequence: String,
        sendsPrefix: Bool = true,
        systemImage: String = "terminal"
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.sequence = sequence
        self.sendsPrefix = sendsPrefix
        self.systemImage = systemImage
    }

    func bytes(prefix: String) throws -> [UInt8] {
        let actionBytes = try TerminalKeySequence.parse(sequence)
        guard sendsPrefix else { return actionBytes }
        return try TerminalKeySequence.parse(prefix) + actionBytes
    }

    static let builtIn: [TmuxCommand] = [
        .init(id: "session-list", title: "Choose Session", detail: "Browse active sessions", sequence: "s", systemImage: "list.bullet.rectangle"),
        .init(id: "detach", title: "Detach Session", detail: "Leave tmux running", sequence: "d", systemImage: "rectangle.portrait.and.arrow.right"),
        .init(id: "new-window", title: "New Window", detail: "Create a tmux window", sequence: "c", systemImage: "plus.rectangle"),
        .init(id: "next-window", title: "Next Window", sequence: "n", systemImage: "arrow.right.square"),
        .init(id: "previous-window", title: "Previous Window", sequence: "p", systemImage: "arrow.left.square"),
        .init(id: "last-window", title: "Last Window", sequence: "l", systemImage: "arrow.uturn.backward.square"),
        .init(id: "split-vertical", title: "Split Left and Right", sequence: "%", systemImage: "rectangle.split.2x1"),
        .init(id: "split-horizontal", title: "Split Top and Bottom", sequence: "\"", systemImage: "rectangle.split.1x2"),
        .init(id: "next-pane", title: "Next Pane", sequence: "o", systemImage: "rectangle.3.group"),
        .init(id: "zoom-pane", title: "Zoom Pane", sequence: "z", systemImage: "arrow.up.left.and.arrow.down.right"),
        .init(id: "copy-mode", title: "Copy Mode", sequence: "[", systemImage: "doc.on.doc"),
        .init(id: "command-prompt", title: "Command Prompt", sequence: ":", systemImage: "command"),
    ]
}
