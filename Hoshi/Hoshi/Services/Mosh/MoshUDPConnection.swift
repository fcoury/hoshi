import Foundation
import Network

@MainActor
protocol MoshUDPTransport: AnyObject {
    var isReady: Bool { get }

    func connect(stateHandler: @escaping (NWConnection.State) -> Void)
    func send(_ data: Data) async throws
    func receiveStream() -> AsyncStream<Data>
    func disconnect()
    func reconnect()
}

// Manages the NWConnection-based UDP link to the remote mosh-server
@MainActor
final class MoshUDPConnection: MoshUDPTransport {
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

        conn.stateUpdateHandler = { [weak self, weak conn] state in
            Task { @MainActor in
                guard let self,
                      let conn,
                      self.connection === conn else {
                    return
                }

                switch state {
                case .ready:
                    self.isReady = true
                case .failed, .cancelled:
                    self.isReady = false
                default:
                    break
                }
                stateHandler(state)
            }
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

    // Create an async stream of incoming datagrams.
    // The inner task is cancelled via onTermination so that cancelling the
    // outer consumer (receiveTask in MoshSession) actually stops the loop.
    func receiveStream() -> AsyncStream<Data> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    do {
                        let data = try await self.receive()
                        continuation.yield(data)
                    } catch {
                        if Task.isCancelled { break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // Disconnect and release resources
    func disconnect() {
        let wasConnecting = connection != nil
        connection?.cancel()
        connection = nil
        isReady = false
        if wasConnecting {
            stateHandler?(.cancelled)
        }
    }

    // Reconnect after network change — create a new NWConnection to the same endpoint
    func reconnect() {
        let handler = stateHandler
        disconnect()
        if let handler {
            connect(stateHandler: handler)
        }
    }
}

enum MoshUDPError: LocalizedError {
    case notConnected
    case emptyDatagram
    case connectionFailed(String)
    case noServerResponse(host: String, port: UInt16, seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "UDP connection not established"
        case .emptyDatagram:
            return "Received empty UDP datagram"
        case .connectionFailed(let reason):
            return "UDP connection failed: \(reason)"
        case .noServerResponse(let host, let port, let seconds):
            return "mosh-server did not respond on UDP \(host):\(String(port)) within \(Int(seconds.rounded())) seconds"
        }
    }
}
