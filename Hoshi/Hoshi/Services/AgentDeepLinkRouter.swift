import Foundation

enum AgentDeepLink: Equatable, Sendable {
    case inbox(eventID: UUID?)
    case session(sessionID: UUID, eventID: UUID?)
    case server(serverID: UUID, eventID: UUID?)

    var url: URL {
        var components = URLComponents()
        components.scheme = "hoshi"

        switch self {
        case .inbox(let eventID):
            components.host = "inbox"
            if let eventID {
                components.queryItems = [URLQueryItem(name: "event", value: eventID.uuidString)]
            }
        case .session(let sessionID, let eventID):
            components.host = "session"
            components.path = "/\(sessionID.uuidString)"
            if let eventID {
                components.queryItems = [URLQueryItem(name: "event", value: eventID.uuidString)]
            }
        case .server(let serverID, let eventID):
            components.host = "server"
            components.path = "/\(serverID.uuidString)"
            if let eventID {
                components.queryItems = [URLQueryItem(name: "event", value: eventID.uuidString)]
            }
        }

        return components.url!
    }

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "hoshi" else { return nil }

        let eventID: UUID?
        if let value = components.queryItems?.first(where: { $0.name == "event" })?.value {
            guard let identifier = UUID(uuidString: value) else { return nil }
            eventID = identifier
        } else {
            eventID = nil
        }

        switch components.host?.lowercased() {
        case "inbox":
            guard components.path.isEmpty || components.path == "/" else { return nil }
            self = .inbox(eventID: eventID)
        case "session":
            let value = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let sessionID = UUID(uuidString: value) else { return nil }
            self = .session(sessionID: sessionID, eventID: eventID)
        case "server":
            let value = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let serverID = UUID(uuidString: value) else { return nil }
            self = .server(serverID: serverID, eventID: eventID)
        default:
            return nil
        }
    }
}

@MainActor @Observable
final class AgentDeepLinkRouter {
    static let shared = AgentDeepLinkRouter()

    private(set) var pendingRoute: AgentDeepLink?

    @discardableResult
    func route(_ url: URL) -> Bool {
        guard let route = AgentDeepLink(url: url) else { return false }
        pendingRoute = route
        return true
    }

    func clear() {
        pendingRoute = nil
    }
}
