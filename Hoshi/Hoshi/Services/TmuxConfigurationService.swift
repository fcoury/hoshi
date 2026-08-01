import Foundation

@MainActor @Observable
final class TmuxConfigurationService {
    static let shared = TmuxConfigurationService()

    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let prefix = "com.hoshi.tmux.prefix"
        static let customCommands = "com.hoshi.tmux.customCommands"
    }

    private(set) var prefix: String {
        didSet { defaults.set(prefix, forKey: Key.prefix) }
    }

    private(set) var customCommands: [TmuxCommand] {
        didSet {
            guard let data = try? JSONEncoder().encode(customCommands) else { return }
            defaults.set(data, forKey: Key.customCommands)
        }
    }

    var commands: [TmuxCommand] {
        TmuxCommand.builtIn + customCommands
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let savedPrefix = defaults.string(forKey: Key.prefix),
           (try? TerminalKeySequence.parse(savedPrefix)) != nil {
            prefix = savedPrefix
        } else {
            prefix = "^B"
        }

        if let data = defaults.data(forKey: Key.customCommands),
           let commands = try? JSONDecoder().decode([TmuxCommand].self, from: data) {
            customCommands = commands
        } else {
            customCommands = []
        }
    }

    func setPrefix(_ notation: String) throws {
        _ = try TerminalKeySequence.parse(notation)
        prefix = notation
    }

    func saveCustomCommand(_ command: TmuxCommand) throws {
        guard !command.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TmuxConfigurationError.missingTitle
        }
        _ = try command.bytes(prefix: prefix)

        if let index = customCommands.firstIndex(where: { $0.id == command.id }) {
            customCommands[index] = command
        } else {
            customCommands.append(command)
        }
    }

    func removeCustomCommand(id: String) {
        customCommands.removeAll { $0.id == id }
    }
}

enum TmuxConfigurationError: LocalizedError, Equatable {
    case missingTitle

    var errorDescription: String? {
        switch self {
        case .missingTitle: "Enter a name for this shortcut."
        }
    }
}
