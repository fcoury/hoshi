import SwiftUI

struct AppRootView: View {
    @Environment(\.scenePhase) private var scenePhase

    private let appearance = AppearanceSettings.shared
    private let appLock = AppLockService.shared

    var body: some View {
        ZStack {
            ServerListView()
                .allowsHitTesting(!appLock.isLocked)
                .accessibilityHidden(appLock.isLocked)

            if appLock.isLocked {
                lockScreen
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(appearance.colorScheme.preferredColorScheme)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                appLock.lock()
            case .active:
                if appLock.isLocked {
                    Task { await appLock.unlock() }
                }
            default:
                break
            }
        }
        .task {
            if appLock.isLocked {
                await appLock.unlock()
            }
        }
    }

    private var lockScreen: some View {
        ZStack {
            Color(appearance.currentTheme.background)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(Color(appearance.currentTheme.accentCyan))

                Text("Hoshi is Locked")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color(appearance.currentTheme.foreground))

                Button("Unlock with \(appLock.authenticationName)") {
                    Task { await appLock.unlock() }
                }
                .buttonStyle(.borderedProminent)

                if let error = appLock.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color(appearance.currentTheme.secondaryForeground))
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
        }
        .accessibilityElement(children: .contain)
    }
}
