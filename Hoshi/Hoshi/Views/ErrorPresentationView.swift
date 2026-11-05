import SwiftUI
import UIKit

/// One consistent, fully inspectable failure presentation for forms, settings, uploads, and terminal tools.
struct ErrorPresentationView: View {
    let presentation: ErrorPresentation
    /// Called after a changed host key was forgotten, e.g. to retry the connection.
    var onHostKeyForgotten: (() -> Void)? = nil

    @State private var confirmForgetHostKey = false
    @State private var forgetHostKeyFailure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(presentation.title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)

            Text(presentation.explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let recovery = presentation.recoverySuggestion {
                Text(recovery)
                    .font(.caption)
                    .foregroundStyle(.blue)
            }

            if let command = presentation.suggestedCommand {
                SuggestedCommandRow(command: command, hostname: presentation.context.hostname)
            }

            if let change = presentation.hostKeyChange {
                Button(role: .destructive) {
                    confirmForgetHostKey = true
                } label: {
                    Label("Forget Old Key and Verify Again", systemImage: "key.slash")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("error.hostkey.forget")
                .confirmationDialog(
                    "Forget the trusted key for \(change.endpoint)?",
                    isPresented: $confirmForgetHostKey,
                    titleVisibility: .visible
                ) {
                    Button("Forget Old Key", role: .destructive) {
                        do {
                            try change.forgetTrustedKey()
                            HapticService.success()
                            onHostKeyForgotten?()
                        } catch {
                            forgetHostKeyFailure = error.localizedDescription
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(HostKeyChange.confirmationMessage(change))
                }

                if let forgetHostKeyFailure {
                    Text(forgetHostKeyFailure)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if let output = presentation.serverOutput {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Server Output")
                        .font(.caption.weight(.semibold))
                    Text(output)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
                .accessibilityIdentifier("error.serverOutput")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Underlying Error")
                    .font(.caption.weight(.semibold))
                Text(presentation.technicalDetails)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                UIPasteboard.general.string = presentation.technicalDetails
                HapticService.success()
            } label: {
                Label("Copy Technical Details", systemImage: "doc.on.doc")
                    .font(.caption)
            }
            .accessibilityHint("Copies sanitized error details without passwords, tokens, or private keys")
        }
        .accessibilityElement(children: .contain)
    }
}

/// A shell command the user can copy and run on the server to fix a failure.
struct SuggestedCommandRow: View {
    let command: String
    let hostname: String?

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(hostname.map { "To fix, run on \($0):" } ?? "To fix, run on the server:")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text(command)
                    .font(.caption.monospaced().weight(.medium))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    UIPasteboard.general.string = command
                    copied = true
                    HapticService.success()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(copied ? "Copied \(command)" : "Copy \(command)")
                .accessibilityIdentifier("error.suggestedCommand.copy")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
