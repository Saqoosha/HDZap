import SwiftUI

@main
struct HDZapApp: App {
    @State private var bluetoothManager = BluetoothManager()
    @State private var lapTimer = LapTimer()

    init() {
        UserDefaults.standard.register(defaults: [
            "raceSessionLimit": 90,
            "accentHue": EditorialTheme.defaultAccentHue,
            "targetLapCount": RaceMetrics.defaultTargetLapCount,
        ])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(bluetoothManager)
                .environment(lapTimer)
        }
    }
}
