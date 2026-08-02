import Foundation

// Connection state shared between SSH and Mosh sessions
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case sshBootstrap
    case moshStarting
    case connected
    case reconnecting
    case error(String)
}

enum ConnectionRecoveryStatus: Equatable, Sendable {
    case idle
    case waitingForNetwork
    case reconnecting
    case unavailable(String)

    var blocksInput: Bool {
        self != .idle
    }
}

// Callback for raw terminal data consumed by the terminal renderer
typealias TerminalDataCallback = @Sendable ([UInt8]) -> Void

// Protocol that both SSHSession and MoshSession conform to,
// allowing the ViewModel and Views to work with either session type
@MainActor
protocol TerminalSession: AnyObject, ObservableObject {
    var connectionState: ConnectionState { get }
    var recoveryStatus: ConnectionRecoveryStatus { get }
    var outputBuffer: String { get set }

    // Raw data callback for feeding bytes directly to the terminal renderer
    var onDataReceived: TerminalDataCallback? { get set }

    func send(_ data: Data) async
    func sendString(_ string: String) async
    func resize(cols: Int, rows: Int) async
    func retryRecovery() async
    func handleAppBackground()
    func disconnect() async
}
