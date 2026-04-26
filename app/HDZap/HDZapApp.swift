import SwiftUI

@main
struct HDZapApp: App {
    @State private var bluetoothManager = BluetoothManager()
    @State private var lapTimer = LapTimer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(bluetoothManager)
                .environment(lapTimer)
        }
    }
}
