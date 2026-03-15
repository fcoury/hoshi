import SwiftUI
import SwiftData
import CoreText

@main
struct HoshiApp: App {
    init() {
        // Register all bundled fonts with Core Text before Ghostty initializes,
        // so they're discoverable by the terminal's font lookup.
        Self.registerBundledFonts()

        // AppearanceSettings must init before GhosttyRuntimeController reads from it
        _ = AppearanceSettings.shared
        _ = GhosttyRuntimeController.shared
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

    // Switch this to .neonPulse or .constellation to try the other variations
    private static let splashStyle: SplashStyle = .terminalBoot

    var body: some Scene {
        WindowGroup {
            SplashContainerView(style: Self.splashStyle)
        }
        .modelContainer(for: [Server.self])
    }
}
