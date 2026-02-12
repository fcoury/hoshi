import SwiftUI
import SwiftData

@main
struct HoshiApp: App {
    var body: some Scene {
        WindowGroup {
            ServerListView()
        }
        .modelContainer(for: [Server.self])
    }
}
