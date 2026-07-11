import SwiftUI

@main
struct HDZapWatchApp: App {
    @State private var workout = WatchWorkoutManager()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environment(workout)
        }
    }
}
