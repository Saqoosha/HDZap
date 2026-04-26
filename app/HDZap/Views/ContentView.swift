import SwiftUI

struct ContentView: View {
    var body: some View {
        TimerView()
            .preferredColorScheme(.light)
            .tint(EditorialTheme.accent)
    }
}
