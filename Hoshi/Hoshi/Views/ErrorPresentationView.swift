import SwiftUI
import UIKit

/// One consistent, fully inspectable failure presentation for forms, settings, uploads, and terminal tools.
struct ErrorPresentationView: View {
    let presentation: ErrorPresentation

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
