import SwiftUI
import SwiftData
import CoreText
import UIKit

final class HoshiAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AgentNotificationService.shared.configure()
        return true
    }
}

@main
struct HoshiApp: App {
    @UIApplicationDelegateAdaptor(HoshiAppDelegate.self) private var appDelegate

    init() {
        #if DEBUG
        // `-HoshiResetKeyBars`: back to the default Shell bar and key sets, no pins.
        if ProcessInfo.processInfo.arguments.contains("-HoshiResetKeyBars") {
            for key in ["com.hoshi.toolbar.buttons", "com.hoshi.keyProfiles.v1", "com.hoshi.keyProfiles.pins"] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        #endif

        // Register all bundled fonts with Core Text before Ghostty initializes,
        // so they're discoverable by the terminal's font lookup.
        Self.registerBundledFonts()

        // AppearanceSettings must init before GhosttyRuntimeController reads from it
        _ = AppearanceSettings.shared
        _ = GhosttyRuntimeController.shared

        ToolbarTips.configure()
    }

    // Register every .ttf/.otf in the Fonts resource directory with Core Text.
    // UIAppFonts handles this for UIKit, but Ghostty uses Core Text directly
    // and needs fonts registered before its runtime initializes.
    private static func registerBundledFonts() {
        // Font files land at the bundle root (flat), not in a Fonts/ subdirectory.
        guard let bundleURL = Bundle.main.resourceURL else { return }

        let fontExtensions: Set<String> = ["ttf", "otf"]

        guard let enumerator = FileManager.default.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return }

        for case let fileURL as URL in enumerator {
            guard fontExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            CTFontManagerRegisterFontsForURL(fileURL as CFURL, .process, nil)
        }
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
        .modelContainer(for: [Server.self])
    }
}
