import UIKit

// Centralized haptic feedback for key interaction moments.
// Each generator is prepared on creation and re-prepared after
// each firing so the Taptic Engine stays warm for the next event.
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
