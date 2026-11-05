#if DEBUG
import Foundation
import SwiftData

/// Debug-only fixture loader for the App Store screenshot pipeline
/// (`scripts/screenshots/`). Never compiled into Release builds.
///
/// The capture script launches the app with `HOSHI_SCREENSHOT_SEED` set to a
/// base64-encoded JSON document (via `SIMCTL_CHILD_HOSHI_SCREENSHOT_SEED`).
/// When present, every saved server is replaced with the seeded ones, their
/// passwords go to the Keychain, and the seeded host keys are trusted, so the
/// screenshot host's containers connect without prompts.
///
/// Everything else the pipeline needs (settings, cleared session restore,
/// cleared inbox) is plain UserDefaults and is written by the script itself.
enum ScreenshotSeed {
    static let environmentKey = "HOSHI_SCREENSHOT_SEED"

    struct Document: Decodable {
        var servers: [SeedServer]
        var knownHosts: [SeedHostKey]?
    }

    struct SeedServer: Decodable {
        var name: String
        var hostname: String
        var port: Int
        var username: String
        var password: String
        var transport: ConnectionTransportPolicy?
        var tmux: TmuxConnectionPolicy?
        var tmuxSession: String?
        var udpPortRange: String?
        var favorite: Bool?
    }

    /// `key` is the OpenSSH public key line, e.g. `ssh-ed25519 AAAA…`.
    struct SeedHostKey: Decodable {
        var hostname: String
        var port: Int
        var key: String
    }

    static var isActive: Bool {
        ProcessInfo.processInfo.environment[environmentKey] != nil
    }

    @MainActor
    static func applyIfRequested(context: ModelContext) {
        guard let encoded = ProcessInfo.processInfo.environment[environmentKey] else { return }
        do {
            guard let data = Data(base64Encoded: encoded) else {
                throw SeedError("seed is not valid base64")
            }
            let document = try JSONDecoder().decode(Document.self, from: data)
            try apply(document, context: context)
            print("[ScreenshotSeed] seeded \(document.servers.count) servers")
        } catch {
            print("[ScreenshotSeed] failed: \(error)")
        }
    }

    @MainActor
    private static func apply(_ document: Document, context: ModelContext) throws {
        let keychain = KeychainService.shared

        for server in try context.fetch(FetchDescriptor<Server>()) {
            try? keychain.deletePassword(forServer: server.id)
            context.delete(server)
        }

        for seed in document.servers {
            let server = Server(
                name: seed.name,
                hostname: seed.hostname,
                port: seed.port,
                username: seed.username,
                authMethod: .password,
                isFavorite: seed.favorite ?? false,
                tmuxSession: seed.tmuxSession,
                transportPolicy: seed.transport ?? .auto,
                tmuxPolicy: seed.tmux,
                moshUDPPortRange: seed.udpPortRange
            )
            context.insert(server)
            try keychain.storePassword(seed.password, forServer: server.id)
        }
        try context.save()

        for hostKey in document.knownHosts ?? [] {
            let parts = hostKey.key.split(separator: " ")
            guard parts.count >= 2 else { throw SeedError("malformed host key for \(hostKey.hostname)") }
            let algorithm = String(parts[0])
            let line = "\(parts[0]) \(parts[1])"
            try? keychain.deleteKnownHostKey(hostname: hostKey.hostname, port: hostKey.port, algorithm: algorithm)
            try keychain.storeKnownHostKey(line, hostname: hostKey.hostname, port: hostKey.port, algorithm: algorithm)
        }
    }

    private struct SeedError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
#endif
