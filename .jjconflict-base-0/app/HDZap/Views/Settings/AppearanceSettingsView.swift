import SwiftUI

/// Highlight color picker — drives the timer + best-lap + split highlights
/// across the app. Single setting, dedicated screen so the gradient
/// preview has room to read clearly.
struct AppearanceSettingsView: View {
    @AppStorage("accentHue") private var accentHue: Double = EditorialTheme.defaultAccentHue

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Highlight color")
                        Spacer()
                        Text("\(Int(accentHue.rounded()))°")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Slider(value: $accentHue, in: 0...360, step: 1)
                        .tint(EditorialTheme.accent(hue: accentHue))

                    LinearGradient(
                        colors: stride(from: 0.0, through: 360.0, by: 30.0).map {
                            EditorialTheme.accent(hue: $0)
                        },
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .clipShape(.capsule)
                    .frame(height: 8)

                    HStack(spacing: 12) {
                        Circle()
                            .fill(EditorialTheme.accent(hue: accentHue))
                            .frame(width: 14, height: 14)
                        Text("Best lap")
                            .foregroundStyle(EditorialTheme.accent(hue: accentHue))
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        Button("Reset") { accentHue = EditorialTheme.defaultAccentHue }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                Text("Hue used for the live timer, best-lap marker, and split highlights.")
                    .font(.caption2)
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}
