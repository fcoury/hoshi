import Foundation
import GhosttyKit

/// Identity advertised to remote programs running inside Hoshi's embedded terminal.
///
/// Keep `TERM` on the broadly supported `xterm-256color` value. Programs such as
/// Codex use `TERM_PROGRAM` to identify Ghostty-specific capabilities like OSC 9.
enum TerminalIdentity {
    static let program = "ghostty"

    static let version: String = {
        let info = ghostty_info()
        guard let pointer = info.version, info.version_len > 0 else { return "" }
        let bytes = UnsafeBufferPointer(
            start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self),
            count: Int(info.version_len)
        )
        return String(decoding: bytes, as: UTF8.self)
    }()

    static var environment: [(name: String, value: String)] {
        var values = [(name: "TERM_PROGRAM", value: program)]
        if !version.isEmpty {
            values.append((name: "TERM_PROGRAM_VERSION", value: version))
        }
        return values
    }
}
