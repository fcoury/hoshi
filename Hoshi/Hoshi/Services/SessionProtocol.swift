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

// Callback for raw terminal data — SwiftTerm consumes bytes directly
typealias TerminalDataCallback = @Sendable ([UInt8]) -> Void

// Protocol that both SSHSession and MoshSession conform to,
// allowing the ViewModel and Views to work with either session type
@MainActor
protocol TerminalSession: AnyObject, ObservableObject {
    var connectionState: ConnectionState { get }
    var outputBuffer: String { get set }

    // Raw data callback for feeding bytes directly to SwiftTerm
    var onDataReceived: TerminalDataCallback? { get set }

    func send(_ data: Data) async
    func sendString(_ string: String) async
    func resize(cols: Int, rows: Int) async
    func disconnect() async
}
