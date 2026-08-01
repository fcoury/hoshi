import Foundation
import Security

enum AgentCompanionError: LocalizedError, Equatable {
    case invalidEndpoint
    case insecureEndpoint
    case missingToken
    case invalidToken
    case invalidResponse
    case responseTooLarge
    case unsupportedVersion(Int)
    case httpStatus(Int)
    case credentialStorage(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "Enter a valid companion URL."
        case .insecureEndpoint:
            "Companion connections require HTTPS. HTTP is allowed only for localhost."
        case .missingToken:
            "Add a companion authentication token."
        case .invalidToken:
            "The companion authentication token must contain at least 16 characters."
        case .invalidResponse:
            "The companion returned an invalid event feed."
        case .responseTooLarge:
            "The companion event feed exceeded its size limit."
        case .unsupportedVersion(let version):
            "Companion protocol version \(version) is not supported."
        case .httpStatus(let status):
            "Companion request failed with HTTP status \(status)."
        case .credentialStorage(let status):
            "Unable to access the companion token in Keychain (status: \(status))."
        }
    }
}

@MainActor
protocol AgentCompanionTokenStoring: AnyObject {
    func load() throws -> String?
    func save(_ token: String) throws
    func delete() throws
}

@MainActor
final class SystemAgentCompanionTokenStore: AgentCompanionTokenStoring {
    private let service = "app.gethoshi.agent-companion"
    private let account = "bearer-token"

    func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw AgentCompanionError.credentialStorage(status)
        }
        return token
    }

    func save(_ token: String) throws {
        guard let data = token.data(using: .utf8) else { throw AgentCompanionError.invalidToken }

        let deletionStatus = SecItemDelete(baseQuery as CFDictionary)
        guard deletionStatus == errSecSuccess || deletionStatus == errSecItemNotFound else {
            throw AgentCompanionError.credentialStorage(deletionStatus)
        }

        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AgentCompanionError.credentialStorage(status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AgentCompanionError.credentialStorage(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

@MainActor @Observable
final class AgentCompanionConfiguration {
    static let shared = AgentCompanionConfiguration()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let tokens: any AgentCompanionTokenStoring

    private enum Key {
        static let enabled = "app.gethoshi.agent-companion.enabled"
        static let endpoint = "app.gethoshi.agent-companion.endpoint"
        static let cursor = "app.gethoshi.agent-companion.cursor"
    }

    private(set) var isEnabled: Bool
    private(set) var endpoint: URL?
    private(set) var cursor: String?

    init(
        defaults: UserDefaults = .standard,
        tokens: (any AgentCompanionTokenStoring)? = nil
    ) {
        self.defaults = defaults
        self.tokens = tokens ?? SystemAgentCompanionTokenStore()
        self.isEnabled = defaults.bool(forKey: Key.enabled)
        self.endpoint = defaults.string(forKey: Key.endpoint).flatMap(URL.init(string:))
        self.cursor = defaults.string(forKey: Key.cursor)
    }

    var hasToken: Bool {
        (try? tokens.load()) != nil
    }

    func configure(endpoint rawEndpoint: String, token: String) throws {
        let trimmed = rawEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme != nil,
              components.host != nil else {
            throw AgentCompanionError.invalidEndpoint
        }
        guard Self.isSecureEndpoint(url) else { throw AgentCompanionError.insecureEndpoint }

        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedToken.utf8.count >= 16,
              trimmedToken.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }) else {
            throw AgentCompanionError.invalidToken
        }
        try tokens.save(trimmedToken)

        if endpoint != url {
            cursor = nil
            defaults.removeObject(forKey: Key.cursor)
        }
        endpoint = url
        isEnabled = true
        defaults.set(url.absoluteString, forKey: Key.endpoint)
        defaults.set(true, forKey: Key.enabled)
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard endpoint != nil else { throw AgentCompanionError.invalidEndpoint }
            guard try tokens.load() != nil else { throw AgentCompanionError.missingToken }
        }
        isEnabled = enabled
        defaults.set(enabled, forKey: Key.enabled)
    }

    func removeConfiguration() throws {
        try tokens.delete()
        isEnabled = false
        endpoint = nil
        cursor = nil
        defaults.removeObject(forKey: Key.enabled)
        defaults.removeObject(forKey: Key.endpoint)
        defaults.removeObject(forKey: Key.cursor)
    }

    func loadToken() throws -> String {
        guard let token = try tokens.load() else { throw AgentCompanionError.missingToken }
        return token
    }

    func updateCursor(_ value: String?) {
        cursor = value
        if let value {
            defaults.set(value, forKey: Key.cursor)
        } else {
            defaults.removeObject(forKey: Key.cursor)
        }
    }

    nonisolated static func isSecureEndpoint(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.fragment == nil else {
            return false
        }

        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }
}

struct AgentCompanionBatch: Codable, Equatable, Sendable {
    let version: Int
    let events: [AgentEventEnvelope]
    let nextCursor: String?
}

protocol AgentCompanionFetching: Sendable {
    func fetchEvents(endpoint: URL, bearerToken: String, cursor: String?) async throws -> AgentCompanionBatch
}

actor AgentCompanionClient: AgentCompanionFetching {
    static let maximumResponseBytes = 262_144
    static let maximumBatchEvents = 100

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 20
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(
                configuration: configuration,
                delegate: AgentCompanionRedirectDelegate(),
                delegateQueue: nil
            )
        }
    }

    func fetchEvents(endpoint: URL, bearerToken: String, cursor: String?) async throws -> AgentCompanionBatch {
        guard AgentCompanionConfiguration.isSecureEndpoint(endpoint) else {
            throw AgentCompanionError.insecureEndpoint
        }

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        guard components != nil else { throw AgentCompanionError.invalidEndpoint }
        if let cursor {
            var queryItems = components?.queryItems ?? []
            queryItems.removeAll { $0.name == "after" }
            queryItems.append(URLQueryItem(name: "after", value: cursor))
            components?.queryItems = queryItems
        }
        guard let url = components?.url else { throw AgentCompanionError.invalidEndpoint }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()

        guard let response = response as? HTTPURLResponse else {
            throw AgentCompanionError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw AgentCompanionError.httpStatus(response.statusCode)
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw AgentCompanionError.responseTooLarge
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let batch = try? decoder.decode(AgentCompanionBatch.self, from: data) else {
            throw AgentCompanionError.invalidResponse
        }
        guard batch.version == AgentEventEnvelope.supportedVersion else {
            throw AgentCompanionError.unsupportedVersion(batch.version)
        }
        guard batch.events.count <= Self.maximumBatchEvents,
              batch.events.allSatisfy(\.isValid),
              (batch.nextCursor?.utf8.count ?? 0) <= 512 else {
            throw AgentCompanionError.invalidResponse
        }
        return batch
    }
}

/// Companion bearer tokens must never be forwarded to a redirected origin.
private final class AgentCompanionRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

@MainActor @Observable
final class AgentCompanionMonitor {
    static let shared = AgentCompanionMonitor()

    @ObservationIgnored private let configuration: AgentCompanionConfiguration
    @ObservationIgnored private let eventCenter: AgentEventCenter
    @ObservationIgnored private let client: any AgentCompanionFetching
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var pollingGeneration: UUID?

    private(set) var isPolling = false
    private(set) var lastSync: Date?
    private(set) var lastError: String?

    init(
        configuration: AgentCompanionConfiguration? = nil,
        eventCenter: AgentEventCenter? = nil,
        client: (any AgentCompanionFetching)? = nil
    ) {
        self.configuration = configuration ?? .shared
        self.eventCenter = eventCenter ?? .shared
        self.client = client ?? AgentCompanionClient()
    }

    func start() {
        guard configuration.isEnabled, pollingTask == nil else { return }
        let generation = UUID()
        pollingGeneration = generation
        isPolling = true
        pollingTask = Task { [weak self] in
            var failures = 0

            while !Task.isCancelled {
                guard let self,
                      self.pollingGeneration == generation,
                      self.configuration.isEnabled else { break }

                do {
                    _ = try await self.syncOnce()
                    failures = 0
                } catch is CancellationError {
                    break
                } catch {
                    self.lastError = error.localizedDescription
                    failures = min(failures + 1, 5)
                }

                let delay = failures == 0 ? 15.0 : min(60.0, pow(2.0, Double(failures)))
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    break
                }
            }

            if self?.pollingGeneration == generation {
                self?.pollingGeneration = nil
                self?.pollingTask = nil
                self?.isPolling = false
            }
        }
    }

    func stop() {
        pollingGeneration = nil
        pollingTask?.cancel()
        pollingTask = nil
        isPolling = false
    }

    @discardableResult
    func syncOnce() async throws -> Int {
        guard let endpoint = configuration.endpoint else {
            throw AgentCompanionError.invalidEndpoint
        }

        let token = try configuration.loadToken()
        let batch = try await client.fetchEvents(
            endpoint: endpoint,
            bearerToken: token,
            cursor: configuration.cursor
        )

        var accepted = 0
        for event in batch.events {
            if eventCenter.ingestCompanion(event) != nil {
                accepted += 1
            }
        }
        configuration.updateCursor(batch.nextCursor)
        lastSync = Date()
        lastError = nil
        return accepted
    }
}
