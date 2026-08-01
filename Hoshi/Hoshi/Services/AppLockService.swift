import Foundation
import LocalAuthentication

@MainActor
protocol AppLockAuthenticating: AnyObject {
    var biometryType: LABiometryType { get }
    func canAuthenticate() -> Bool
    func authenticate(reason: String) async throws -> Bool
}

@MainActor
final class SystemAppLockAuthenticator: AppLockAuthenticating {
    var biometryType: LABiometryType {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        return context.biometryType
    }

    func canAuthenticate() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func authenticate(reason: String) async throws -> Bool {
        try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }
}

@MainActor @Observable
final class AppLockService {
    static let shared = AppLockService()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let authenticator: any AppLockAuthenticating
    @ObservationIgnored private var authenticationInProgress = false

    private static let enabledKey = "com.hoshi.security.appLockEnabled"

    private(set) var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }

    private(set) var isLocked: Bool
    private(set) var errorMessage: String?
    private(set) var presentedError: ErrorPresentation?

    var isAvailable: Bool { authenticator.canAuthenticate() }

    var authenticationName: String {
        switch authenticator.biometryType {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        default: "Device Passcode"
        }
    }

    init(
        defaults: UserDefaults = .standard,
        authenticator: (any AppLockAuthenticating)? = nil
    ) {
        self.defaults = defaults
        self.authenticator = authenticator ?? SystemAppLockAuthenticator()
        let enabled = defaults.bool(forKey: Self.enabledKey)
        isEnabled = enabled
        isLocked = enabled
    }

    func setEnabled(_ enabled: Bool) async {
        errorMessage = nil
        presentedError = nil

        guard enabled else {
            isEnabled = false
            isLocked = false
            return
        }

        guard authenticator.canAuthenticate() else {
            presentAuthenticationError(ErrorMessageFailure(
                message: "Set up Face ID, Touch ID, or a device passcode to enable app lock."
            ))
            return
        }

        do {
            if try await authenticator.authenticate(reason: "Enable Hoshi app lock") {
                isEnabled = true
                isLocked = false
            }
        } catch {
            presentAuthenticationError(error)
        }
    }

    func lock() {
        guard isEnabled else { return }
        isLocked = true
    }

    func unlock() async {
        guard isEnabled, isLocked, !authenticationInProgress else { return }
        authenticationInProgress = true
        defer { authenticationInProgress = false }

        do {
            if try await authenticator.authenticate(reason: "Unlock your Hoshi terminal sessions") {
                isLocked = false
                errorMessage = nil
                presentedError = nil
            }
        } catch {
            presentAuthenticationError(error)
        }
    }

    private func presentAuthenticationError(_ error: any Error) {
        if let authenticationError = error as? LAError,
           [.userCancel, .appCancel, .systemCancel].contains(authenticationError.code) {
            errorMessage = nil
            presentedError = nil
            return
        }

        let presentation = ErrorPresentation.classify(
            error,
            context: ErrorContext(operation: .biometrics)
        )
        presentedError = presentation
        errorMessage = presentation.explanation
    }
}
