import UIKit

/// Centralized haptic feedback for user-facing interaction moments.
///
/// Three feedback tiers map to three UX categories:
/// - **Selection** (`selection()`) — lightweight click for modifier key toggles
/// - **Impact** (`lightTap()`, `mediumTap()`) — tactile punch for button presses and swipe arrows
/// - **Notification** (`success()`, `warning()`, `error()`) — system-level feedback for connection state transitions
///
/// Each `UIFeedbackGenerator` is lazily initialized as a static singleton, prepared eagerly,
/// and re-prepared after every fire so the Taptic Engine stays warm for the next event.
///
/// All methods must be called from the main thread (UIKit requirement for feedback generators).
/// In practice this is guaranteed because callers are SwiftUI gesture handlers and `onChange` closures.
enum HapticService {

    // MARK: - Selection feedback (modifier key toggles)

    private static let selectionGenerator: UISelectionFeedbackGenerator = {
        let gen = UISelectionFeedbackGenerator()
        gen.prepare()
        return gen
    }()

    static func selection() {
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }

    // MARK: - Impact feedback (button taps, swipe arrows)

    private static let lightImpact: UIImpactFeedbackGenerator = {
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.prepare()
        return gen
    }()

    private static let mediumImpact: UIImpactFeedbackGenerator = {
        let gen = UIImpactFeedbackGenerator(style: .medium)
        gen.prepare()
        return gen
    }()

    static func lightTap() {
        lightImpact.impactOccurred()
        lightImpact.prepare()
    }

    static func mediumTap() {
        mediumImpact.impactOccurred()
        mediumImpact.prepare()
    }

    // MARK: - Notification feedback (connection state changes)

    private static let notificationGenerator: UINotificationFeedbackGenerator = {
        let gen = UINotificationFeedbackGenerator()
        gen.prepare()
        return gen
    }()

    static func success() {
        notificationGenerator.notificationOccurred(.success)
        notificationGenerator.prepare()
    }

    static func warning() {
        notificationGenerator.notificationOccurred(.warning)
        notificationGenerator.prepare()
    }

    static func error() {
        notificationGenerator.notificationOccurred(.error)
        notificationGenerator.prepare()
    }
}
