import SwiftUI
import SwiftData

@main
struct HoshiApp: App {
    init() {
        // AppearanceSettings must init before GhosttyRuntimeController reads from it
        _ = AppearanceSettings.shared
        _ = GhosttyRuntimeController.shared
    }

    var body: some Scene {
        WindowGroup {
            ServerListView()
        }
        .modelContainer(for: [Server.self])
    }
}
