import Foundation
import UIKit
import GhosttyKit
import os.log

@MainActor
final class GhosttyRuntimeController: ObservableObject {
    static let shared = GhosttyRuntimeController()

    private let logger = Logger(subsystem: "com.hoshi.app", category: "ghostty")

    @Published private(set) var isReady = false

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?

    private init() {
        initialize()
    }

    deinit {
        if let app {
            ghostty_app_free(app)
        }
        if let config {
            ghostty_config_free(config)
        }
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    private func initialize() {
        let initResult = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard initResult == GHOSTTY_SUCCESS else {
            logger.error("ghostty_init failed with code \(initResult)")
            return
        }

        guard let cfg = ghostty_config_new() else {
            logger.error("ghostty_config_new failed")
            return
        }

        GhosttyThemeAdapter.apply(to: cfg)
        ghostty_config_finalize(cfg)
        config = cfg

        var runtimeConfig = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { userdata in
                GhosttyRuntimeController.wakeup(userdata)
            },
            action_cb: { app, target, action in
                guard let app else { return false }
                return GhosttyRuntimeController.action(app: app, target: target, action: action)
            },
            read_clipboard_cb: { userdata, _, state in
                GhosttyRuntimeController.readClipboard(userdata: userdata, state: state)
            },
            confirm_read_clipboard_cb: { userdata, str, state, _ in
                GhosttyRuntimeController.confirmReadClipboard(userdata: userdata, string: str, state: state)
            },
            write_clipboard_cb: { _, _, content, len, _ in
                GhosttyRuntimeController.writeClipboard(content: content, len: len)
            },
            close_surface_cb: { _, _ in }
        )

        guard let createdApp = ghostty_app_new(&runtimeConfig, cfg) else {
            logger.error("ghostty_app_new failed")
            return
        }

        app = createdApp
        let scheme: ghostty_color_scheme_e = switch AppearanceSettings.shared.colorScheme {
        case .dark: GHOSTTY_COLOR_SCHEME_DARK
        case .light: GHOSTTY_COLOR_SCHEME_LIGHT
        case .system: GHOSTTY_COLOR_SCHEME_DARK
        }
        ghostty_app_set_color_scheme(createdApp, scheme)
        isReady = true
    }

    // Build a fresh config from the given appearance settings (for live surface updates)
    func buildConfig(for settings: AppearanceSettings) -> ghostty_config_t? {
        guard let cfg = ghostty_config_new() else { return nil }
        GhosttyThemeAdapter.apply(to: cfg, settings: settings)
        ghostty_config_finalize(cfg)
        return cfg
    }

    private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async {
            guard let userdata else { return }
            let runtime = Unmanaged<GhosttyRuntimeController>
                .fromOpaque(userdata)
                .takeUnretainedValue()
            runtime.tick()
        }
    }

    private static func action(
        app _: ghostty_app_t,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            if target.tag == GHOSTTY_TARGET_SURFACE,
               let surface = target.target.surface {
                GhosttyTerminalSurfaceView.requestRender(for: surface)
            }
            return true

        case GHOSTTY_ACTION_SET_TITLE:
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface,
                  let titlePtr = action.action.set_title.title,
                  let title = String(validatingUTF8: titlePtr)
            else {
                return true
            }

            GhosttyTerminalSurfaceView.updateTitle(for: surface, title: title)
            return true

        case GHOSTTY_ACTION_SCROLLBAR:
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface
            else {
                return true
            }

            let sb = action.action.scrollbar
            GhosttyTerminalSurfaceView.updateScrollbar(for: surface, total: sb.total, offset: sb.offset, len: sb.len)
            return true

        default:
            return false
        }
    }

    private static func readClipboard(
        userdata: UnsafeMutableRawPointer?,
        state: UnsafeMutableRawPointer?
    ) {
        guard let userdata, let state else { return }
        let view = Unmanaged<GhosttyTerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        view.completeClipboardRequest(state: state, content: UIPasteboard.general.string ?? "", confirmed: true)
    }

    private static func confirmReadClipboard(
        userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?
    ) {
        guard let userdata, let state else { return }
        let view = Unmanaged<GhosttyTerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        let content = string.flatMap { String(validatingUTF8: $0) } ?? (UIPasteboard.general.string ?? "")
        view.completeClipboardRequest(state: state, content: content, confirmed: true)
    }

    private static func writeClipboard(
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int
    ) {
        guard let content, len > 0 else { return }

        for index in 0..<len {
            let item = content[index]
            guard let mime = item.mime,
                  String(cString: mime) == "text/plain",
                  let payload = item.data
            else {
                continue
            }

            UIPasteboard.general.string = String(cString: payload)
            break
        }
    }
}
