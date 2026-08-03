import Foundation
import UIKit
import GhosttyKit
import os.log

struct TerminalDesktopNotification: Equatable, Sendable {
    let title: String
    let body: String?

    init?(title: String?, body: String?) {
        let normalizedTitle = Self.normalized(title, maximumUTF8Bytes: 512)
        let normalizedBody = Self.normalized(body, maximumUTF8Bytes: 4_096)
        guard normalizedTitle != nil || normalizedBody != nil else { return nil }

        self.title = normalizedTitle ?? "Terminal Notification"
        self.body = normalizedBody
    }

    var agentEventKind: AgentEventKind {
        let text = "\(title) \(body ?? "")".lowercased()
        if text.contains("approval") || text.contains("permission") {
            return .approvalRequested
        }
        if text.contains("needs input")
            || text.contains("waiting for input")
            || text.contains("action required")
            || text.contains("needs attention") {
            return .needsAttention
        }
        return .completed
    }

    var agentEventEnvelope: AgentEventEnvelope {
        AgentEventEnvelope(kind: agentEventKind, title: title, message: body)
    }

    private static func normalized(_ value: String?, maximumUTF8Bytes: Int) -> String? {
        guard let value else { return nil }
        let cleaned = String(value.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar)
        })
        let collapsed = cleaned
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }

        var result = ""
        var byteCount = 0
        for character in collapsed {
            let bytes = String(character).utf8.count
            guard byteCount + bytes <= maximumUTF8Bytes else { break }
            result.append(character)
            byteCount += bytes
        }
        return result.isEmpty ? nil : result
    }
}

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
            confirm_read_clipboard_cb: { userdata, str, state, request in
                GhosttyRuntimeController.confirmReadClipboard(
                    userdata: userdata,
                    string: str,
                    state: state,
                    request: request
                )
            },
            write_clipboard_cb: { userdata, _, content, len, confirm in
                GhosttyRuntimeController.writeClipboard(
                    userdata: userdata,
                    content: content,
                    len: len,
                    requiresConfirmation: confirm
                )
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

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface,
                  let notification = TerminalDesktopNotification(
                      title: action.action.desktop_notification.title.flatMap(String.init(validatingUTF8:)),
                      body: action.action.desktop_notification.body.flatMap(String.init(validatingUTF8:))
                  )
            else {
                return true
            }

            GhosttyTerminalSurfaceView.deliverDesktopNotification(notification, for: surface)
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

        case GHOSTTY_ACTION_COLOR_CHANGE:
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface
            else {
                return true
            }

            let change = action.action.color_change
            guard change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND else {
                return true
            }
            GhosttyTerminalSurfaceView.updateBackgroundColor(
                for: surface,
                red: change.r,
                green: change.g,
                blue: change.b
            )
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
        view.completeClipboardRequest(state: state, content: TerminalPasteboard.shared.string ?? "", confirmed: false)
    }

    private static func confirmReadClipboard(
        userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let userdata, let state else { return }
        let view = Unmanaged<GhosttyTerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        let content: String
        if let string, request != GHOSTTY_CLIPBOARD_REQUEST_PASTE {
            switch TerminalClipboardPayload.decodeCString(string) {
            case .success(let decoded):
                content = decoded
            case .failure(let error):
                view.rejectRemoteClipboardPayload(error, state: state)
                return
            }
        } else {
            content = string.flatMap { String(validatingUTF8: $0) }
                ?? (TerminalPasteboard.shared.string ?? "")
        }
        view.requestClipboardConfirmation(state: state, content: content, request: request)
    }

    private static func writeClipboard(
        userdata: UnsafeMutableRawPointer?,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        requiresConfirmation: Bool
    ) {
        guard let userdata, let content, len > 0 else { return }
        let view = Unmanaged<GhosttyTerminalSurfaceView>
            .fromOpaque(userdata)
            .takeUnretainedValue()

        for index in 0..<len {
            let item = content[index]
            guard let mime = item.mime,
                  case .success("text/plain") = TerminalClipboardPayload.decodeCString(mime, maximumBytes: 128),
                  let payload = item.data
            else {
                continue
            }

            switch TerminalClipboardPayload.decodeCString(payload) {
            case .success(let text):
                view.requestRemoteClipboardWrite(text, requiresConfirmation: requiresConfirmation)
            case .failure(let error):
                view.rejectRemoteClipboardPayload(error)
            }
            break
        }
    }
}
