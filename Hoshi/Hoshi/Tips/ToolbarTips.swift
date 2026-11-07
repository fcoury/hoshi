import Foundation
import SwiftUI
import TipKit

/// One-time hints for the key bar: switching key sets, customizing keys, and the
/// arrow joystick. Shown one at a time above the key bar (see `TerminalView`).
enum ToolbarTips {
    /// `-HoshiResetTips` shows every tip again; screenshot and film runs hide them.
    static func configure() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-HoshiResetTips") {
            try? Tips.resetDatastore()
            UserDefaults.standard.removeObject(forKey: sessionCountKey)
            UserDefaults.standard.removeObject(forKey: arrowTapCountKey)
        }
        if (ScreenshotSeed.isActive && !arguments.contains("-HoshiShowTips")) || arguments.contains("-HoshiHideTips") {
            Tips.hideAllTipsForTesting()
        }
        try? Tips.configure([.displayFrequency(.immediate)])
    }

    private static let sessionCountKey = "com.hoshi.tips.terminalSessions"

    /// Counts connected terminal sessions; the key set tip shows from the second
    /// one even when no app on the server ever switched the keys.
    private static let arrowTapCountKey = "com.hoshi.tips.arrowKeyTaps"

    @MainActor
    static func recordConnectedSession(defaults: UserDefaults = .standard) {
        let count = defaults.integer(forKey: sessionCountKey) + 1
        defaults.set(count, forKey: sessionCountKey)
        if count >= 2 { KeySetTip.isEligible = true }
        // The default bar has no arrow keys to count, so sessions alone earn the arrow tip.
        if count >= 3 { ArrowJoystickTip.isEligible = true }
    }

    static func recordArrowKeyTap(defaults: UserDefaults = .standard) {
        let count = defaults.integer(forKey: arrowTapCountKey) + 1
        defaults.set(count, forKey: arrowTapCountKey)
        if count >= 3 { ArrowJoystickTip.isEligible = true }
    }
}

/// Tip 1: the bar follows the running app, and holding any key picks a set by hand.
struct KeySetTip: Tip {
    /// Set when the bar first switches on its own, or on the second session.
    @Parameter static var isEligible: Bool = false

    var title: Text { Text("Keys for every app") }
    var message: Text? {
        Text("The key bar switches for the app you're in. Hold any key to pick a key set yourself.")
    }
    var image: Image? { Image(systemName: "rectangle.stack") }
    var rules: [Rule] { [#Rule(Self.$isEligible) { $0 == true }] }
}

/// Tip 2: the keys themselves are editable. Unlocked once tip 1 is done.
struct CustomizeKeysTip: Tip {
    @Parameter static var isUnlocked: Bool = false

    var title: Text { Text("Make the keys yours") }
    var message: Text? {
        Text("Hold \(Image(systemName: "keyboard.chevron.compact.down")) at the end of the bar to add, remove or reorder keys, or make your own.")
    }
    var image: Image? { Image(systemName: "slider.horizontal.3") }
    var rules: [Rule] { [#Rule(Self.$isUnlocked) { $0 == true }] }
}

/// Tip 3: after a few taps on arrow keys, or by the third session, point at the joystick.
struct ArrowJoystickTip: Tip {
    @Parameter static var isEligible: Bool = false
    /// Mirrors Settings > Long Press: the joystick only exists for "Arrow Keys".
    @Parameter static var joystickEnabled: Bool = true

    var title: Text { Text("Arrows without arrow keys") }
    var message: Text? {
        Text("Hold anywhere on the terminal and drag. It's a joystick: keep holding to repeat.")
    }
    var image: Image? { Image(systemName: "dpad") }
    var rules: [Rule] {
        [
            #Rule(Self.$joystickEnabled) { $0 == true },
            #Rule(Self.$isEligible) { $0 == true },
        ]
    }
}
