import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            Tab("Timer", systemImage: "timer") {
                TimerView()
            }
            Tab("Connection", systemImage: "antenna.radiowaves.left.and.right") {
                ConnectionView()
            }
        }
    }
}
