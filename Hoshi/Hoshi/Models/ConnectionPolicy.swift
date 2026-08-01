import Foundation

enum ConnectionTransportPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case mosh
    case ssh

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Auto"
        case .mosh: "Mosh"
        case .ssh: "SSH"
        }
    }

    var candidateTransports: [ConnectionTransport] {
        switch self {
        case .auto: [.mosh, .ssh]
        case .mosh: [.mosh]
        case .ssh: [.ssh]
        }
    }
}

enum ConnectionTransport: String, Codable, Equatable, Sendable {
    case mosh
    case ssh
}

enum TmuxConnectionPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case alwaysAsk
    case autoAttachLast
    case rawShell

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .alwaysAsk: "Always Ask"
        case .autoAttachLast: "Auto-Attach Last"
        case .rawShell: "Raw Shell"
        }
    }
}

struct MoshPortRange: Equatable, Sendable {
    let lowerBound: UInt16
    let upperBound: UInt16

    init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator: Character = trimmed.contains(":") ? ":" : "-"
        let values = trimmed.split(separator: separator, omittingEmptySubsequences: false)
        guard (1...2).contains(values.count),
              let lowerBound = UInt16(values[0]),
              lowerBound > 0 else {
            return nil
        }

        let upperBound: UInt16
        if values.count == 2 {
            guard let parsedUpperBound = UInt16(values[1]), parsedUpperBound >= lowerBound else {
                return nil
            }
            upperBound = parsedUpperBound
        } else {
            upperBound = lowerBound
        }

        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    var argument: String {
        lowerBound == upperBound ? "\(lowerBound)" : "\(lowerBound):\(upperBound)"
    }
}

struct ReconnectionPolicy: Equatable, Sendable {
    let initialDelay: TimeInterval
    let maximumDelay: TimeInterval
    let maximumAttempts: Int

    static let ssh = ReconnectionPolicy(initialDelay: 1, maximumDelay: 16, maximumAttempts: 5)
    static let mosh = ReconnectionPolicy(initialDelay: 0.25, maximumDelay: 15, maximumAttempts: 8)

    func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        return min(maximumDelay, initialDelay * pow(2, Double(attempt - 1)))
    }
}
