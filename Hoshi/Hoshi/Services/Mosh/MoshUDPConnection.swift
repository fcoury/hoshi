import Foundation
import Network

// Manages the NWConnection-based UDP link to the remote mosh-server
final class MoshUDPConnection {
    private var connection: NWConnection?
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private var stateHandler: ((NWConnection.State) -> Void)?

    // Current connection state
    private(set) var isReady = false

    init(host: String, port: UInt16) {
        self.host = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            fatalError("Invalid port: \(port)")
        }
        self.port = nwPort
    }

    // Establish the UDP connection
    func connect(stateHandler: @escaping (NWConnection.State) -> Void) {
        self.stateHandler = stateHandler

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        let conn = NWConnection(host: host, port: port, using: params)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.isReady = true
            case .failed, .cancelled:
                self?.isReady = false
            default:
                break
            }
            stateHandler(state)
        }

        conn.start(queue: .global(qos: .userInteractive))
    }

    // Send a datagram
    func send(_ data: Data) async throws {
        guard let connection, isReady else {
            throw MoshUDPError.notConnected
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    // Receive a single datagram
    func receive() async throws -> Data {
        guard let connection else {
            throw MoshUDPError.notConnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            connection.receiveMessage { content, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content {
                    continuation.resume(returning: content)
                } else {
                    continuation.resume(throwing: MoshUDPError.emptyDatagram)
                }
            }
        }
    }

    // Create an async stream of incoming datagrams
    func receiveStream() -> AsyncStream<Data> {
        AsyncStream { continuation in
            Task {
                while !Task.isCancelled {
                    do {
                        let data = try await self.receive()
                        continuation.yield(data)
                    } catch {
                        if Task.isCancelled { break }
                        // Brief pause before retrying on transient errors
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                continuation.finish()
            }
        }
    }

    // Disconnect and release resources
    func disconnect() {
        connection?.cancel()
        connection = nil
        isReady = false
    }

    // Reconnect after network change — create a new NWConnection to the same endpoint
    func reconnect() {
        disconnect()
        if let handler = stateHandler {
            connect(stateHandler: handler)
        }
    }
}

enum MoshUDPError: LocalizedError {
    case notConnected
    case emptyDatagram
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "UDP connection not established"
        case .emptyDatagram:
            return "Received empty UDP datagram"
        case .connectionFailed(let reason):
            return "UDP connection failed: \(reason)"
        }
    }
}
