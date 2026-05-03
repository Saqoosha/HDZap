import SwiftUI

@main
struct HDZapApp: App {
    @State private var bluetoothManager = BluetoothManager()
    @State private var lapTimer = LapTimer()
    @State private var lapAnnouncer = LapAnnouncer()

    init() {
        UserDefaults.standard.register(defaults: [
            "raceSessionLimit": 90,
            "accentHue": EditorialTheme.defaultAccentHue,
            "targetLapCount": RaceMetrics.defaultTargetLapCount,
            LapAnnouncerDefaults.enabledKey: false,
            LapAnnouncerDefaults.languageKey: LapAnnouncerDefaults.defaultLanguageRaw,
            LapAnnouncerDefaults.announceBestKey: true,
            LapAnnouncerDefaults.rateKey: Double(LapAnnouncerDefaults.defaultRate),
            LapAnnouncerDefaults.pitchKey: Double(LapAnnouncerDefaults.defaultPitch),
            LapAnnouncerDefaults.voiceIdentifierKey: "",
        ])
        #if DEBUG
        _oklchSanityCheck()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(bluetoothManager)
                .environment(lapTimer)
                .environment(lapAnnouncer)
        }
    }
}
