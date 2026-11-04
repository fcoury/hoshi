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
