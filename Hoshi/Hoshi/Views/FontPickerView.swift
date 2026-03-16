import SwiftUI
import UIKit

// Font picker listing bundled fonts first, then system monospace fonts.
struct FontPickerView: View {
    private let settings = AppearanceSettings.shared

    private let bundledFonts = [
        "FantasqueSansM Nerd Font Mono",
        "JetBrainsMono Nerd Font Mono",
        "FiraCode Nerd Font Mono",
        "Hack Nerd Font Mono",
        "MesloLGS Nerd Font Mono",
        "CaskaydiaCove Nerd Font Mono",
        "SauceCodePro Nerd Font Mono",
        "Iosevka Nerd Font Mono",
        "VictorMono Nerd Font Mono",
        "Mononoki Nerd Font Mono",
        "GeistMono Nerd Font Mono",
    ]

    @State private var systemMonoFonts: [String] = []

    var body: some View {
        List {
            Section("Bundled") {
                ForEach(bundledFonts, id: \.self) { family in
                    fontRow(family)
                }
            }

            Section("System") {
                ForEach(systemMonoFonts, id: \.self) { family in
                    fontRow(family)
                }
            }
        }
        .navigationTitle("Font")
        .onAppear {
            systemMonoFonts = discoverSystemMonoFonts()
        }
    }

    private func fontRow(_ family: String) -> some View {
        Button {
            settings.fontFamily = family
        } label: {
            HStack {
                // Render font name in its own font for preview
                Text(family)
                    .font(.custom(family, size: 16))
                    .foregroundStyle(.primary)

                Spacer()

                if settings.fontFamily == family {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                        .fontWeight(.semibold)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // Discover system monospace fonts by checking the symbolic traits of each family
    private func discoverSystemMonoFonts() -> [String] {
        UIFont.familyNames
            .sorted()
            .filter { family in
                let fontNames = UIFont.fontNames(forFamilyName: family)
                guard let firstName = fontNames.first else { return false }
                let font = UIFont(name: firstName, size: 12)
                let descriptor = font?.fontDescriptor
                let traits = descriptor?.symbolicTraits ?? []
                return traits.contains(.traitMonoSpace)
            }
    }
}
