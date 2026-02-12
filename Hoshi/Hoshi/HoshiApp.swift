import SwiftUI
import SwiftData

@main
struct HoshiApp: App {
    init() {
        _ = GhosttyRuntimeController.shared
    }

    var body: some Scene {
        WindowGroup {
            ServerListView()
        }
        .modelContainer(for: [Server.self])
    }
}
