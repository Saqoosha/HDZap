import SwiftUI

struct ContentView: View {
    @AppStorage("accentHue") private var accentHue: Double = EditorialTheme.defaultAccentHue

    var body: some View {
        TimerView()
            .preferredColorScheme(.light)
            .tint(EditorialTheme.accent(hue: accentHue))
            .environment(\.accentHue, accentHue)
    }
}
