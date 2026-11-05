import Foundation

/// Why mosh-server didn't start, read from what its launch printed. A remote command that
/// exits non-zero loses its output in the SSH client, so the launch command always exits
/// cleanly and reports mosh-server's own status on an `exitMarker` line instead.
struct MoshLaunchFailure: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The shell couldn't find or run the executable.
        case notFound
        /// The executable exists but isn't allowed to run.
        case permissionDenied
        /// It starts, but a shared library it links against is gone, which usually means a
        /// package manager upgraded a dependency underneath it.
        case missingLibrary(String)
        /// mosh-server refuses to run without a UTF-8 locale.
        case localeUnsupported
        /// It was killed by a signal, such as a crash.
        case crashed(signal: Int)
        case unknown
    }

    static let exitMarker = "MOSH SERVER EXIT"

    let kind: Kind
    /// mosh-server's exit status, when the launch command reported it.
    let exitCode: Int?
    /// What the launch printed, without Hoshi's own marker lines.
    let output: String

    init(kind: Kind, exitCode: Int?, output: String) {
        self.kind = kind
        self.exitCode = exitCode
        self.output = output
    }

    /// Reads the output of `MoshBootstrapService.serverLaunchCommand`.
    init(launchOutput: String, exitCode reportedExitCode: Int? = nil) {
        var exitCode = reportedExitCode
        var kept: [Substring] = []
        for line in launchOutput.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix(Self.exitMarker) {
                exitCode = Int(trimmed.dropFirst(Self.exitMarker.count).trimmingCharacters(in: .whitespaces))
            } else if !trimmed.hasPrefix("MOSH SSH_CONNECTION") {
                kept.append(line)
            }
        }
        let output = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(kind: Self.diagnose(output: output, exitCode: exitCode), exitCode: exitCode, output: output)
    }

    private static func diagnose(output: String, exitCode: Int?) -> Kind {
        let lowered = output.lowercased()
        // macOS dyld: "Library not loaded: /opt/homebrew/opt/abseil/lib/libabsl_x.dylib"
        // Linux ld.so: "error while loading shared libraries: libprotobuf.so.32: cannot open..."
        if let library = firstMatch(#"Library not loaded:\s*(\S+)"#, in: output)
            ?? firstMatch(#"error while loading shared libraries:\s*([^:\s]+)"#, in: output) {
            return .missingLibrary((library as NSString).lastPathComponent)
        }
        if lowered.contains("utf-8 native locale") {
            return .localeUnsupported
        }
        if exitCode == 127 || lowered.contains("command not found") || lowered.contains(": not found")
            || lowered.contains("no such file or directory") {
            return .notFound
        }
        if exitCode == 126 || lowered.contains("permission denied") {
            return .permissionDenied
        }
        if let exitCode, exitCode > 128, exitCode < 160 {
            return .crashed(signal: exitCode - 128)
        }
        return .unknown
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// The installation looks like Homebrew's, so `brew` can repair it.
    var isHomebrewInstall: Bool {
        output.contains("/opt/homebrew/") || output.contains("/usr/local/Cellar/")
            || output.contains("/usr/local/opt/") || output.contains("/home/linuxbrew/")
    }

    /// A command that likely fixes it, to run on the server.
    var suggestedCommand: String? {
        switch kind {
        case .missingLibrary, .crashed:
            return isHomebrewInstall ? "brew reinstall mosh" : nil
        default:
            return nil
        }
    }

    /// One sentence on what went wrong.
    var summary: String {
        switch kind {
        case .notFound:
            return "The server couldn't find the mosh-server program."
        case .permissionDenied:
            return "mosh-server is on the server, but this account isn't allowed to run it."
        case .missingLibrary(let library):
            return "mosh-server is installed but can't start: a library it needs (\(library)) is missing."
        case .localeUnsupported:
            return "mosh-server needs a UTF-8 locale on the server, and none is set up."
        case .crashed(let signal):
            return "mosh-server crashed as it started (signal \(signal))."
        case .unknown:
            if let exitCode, exitCode != 0 {
                return "mosh-server exited with status \(exitCode) before it could start a session."
            }
            return "mosh-server didn't start a session."
        }
    }

    /// What to do about it.
    var recovery: String {
        switch kind {
        case .notFound:
            return "Install mosh on the server, or set the mosh-server path in this connection's settings."
        case .permissionDenied:
            return "Make mosh-server executable for this account (chmod +x), or point the connection at another copy."
        case .missingLibrary, .crashed:
            return suggestedCommand == nil
                ? "Reinstall mosh with the server's package manager. A dependency was probably upgraded without it."
                : "Reinstall mosh on the server. A Homebrew upgrade probably replaced a library it was built against."
        case .localeUnsupported:
            return "Generate a UTF-8 locale on the server (for example en_US.UTF-8) and reconnect."
        case .unknown:
            return "Check the server output in Details, then retry Mosh."
        }
    }
}
