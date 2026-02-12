import Foundation
import Network

// Monitors network path changes to trigger mosh session reconnection
@MainActor
@Observable
final class NetworkMonitorService {
    var isConnected = true
    var didChangeNetwork = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.hoshi.networkmonitor")
    private var previousPath: NWPath?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let wasConnected = self.isConnected
                self.isConnected = path.status == .satisfied

                // Detect network interface change (e.g. WiFi -> cellular)
                if let previous = self.previousPath,
                   previous.status == .satisfied,
                   path.status == .satisfied,
                   previous.availableInterfaces != path.availableInterfaces {
                    self.didChangeNetwork = true
                }

                // Detect reconnect after disconnect
                if !wasConnected && self.isConnected {
                    self.didChangeNetwork = true
                }

                self.previousPath = path
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }

    // Reset the change flag after handling the event
    func acknowledgeNetworkChange() {
        didChangeNetwork = false
    }
}
