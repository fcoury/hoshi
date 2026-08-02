import Foundation
import Network

@MainActor
protocol MoshUDPTransport: AnyObject {
    var isReady: Bool { get }

    func connect() async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func disconnect()
}

// Manages the NWConnection-based UDP link to the remote mosh-server
@MainActor
final class MoshUDPConnection: MoshUDPTransport {
    private var connection: NWConnection?
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private var readinessContinuation: CheckedContinuation<Void, Error>?

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
    func connect() async throws {
        disconnect()
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        let conn = NWConnection(host: host, port: port, using: params)
        self.connection = conn

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                readinessContinuation = continuation
                conn.stateUpdateHandler = { [weak self, weak conn] state in
                    Task { @MainActor in
                        guard let self,
                              let conn,
                              self.connection === conn else { return }

                        switch state {
                        case .ready:
                            self.isReady = true
                            self.finishReadiness()
                        case .failed(let error):
                            self.isReady = false
                            self.finishReadiness(throwing: error)
                        case .cancelled:
                            self.isReady = false
                            self.finishReadiness(throwing: CancellationError())
                        default:
                            break
                        }
                    }
                }
                conn.start(queue: .global(qos: .userInteractive))
            }
        } onCancel: {
            Task { @MainActor [weak self, weak conn] in
                guard let self, self.connection === conn else { return }
                self.disconnect()
            }
        }
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

    // Disconnect and release resources
    func disconnect() {
        connection?.cancel()
        connection = nil
        isReady = false
        finishReadiness(throwing: CancellationError())
    }

    private func finishReadiness(throwing error: Error? = nil) {
        guard let continuation = readinessContinuation else { return }
        readinessContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
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
