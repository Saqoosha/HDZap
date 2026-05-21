import SwiftUI

@main
struct HDZapWatchApp: App {
    @State private var coordinator = RaceCoordinator()

    var body: some Scene {
        WindowGroup {
            RaceFaceView()
                .environment(coordinator)
        }
    }
}
