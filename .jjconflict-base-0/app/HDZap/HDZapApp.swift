import SwiftUI

@main
struct HDZapApp: App {
    @State private var bluetoothManager = BluetoothManager()
    @State private var lapTimer = LapTimer()
    @State private var lapAnnouncer = LapAnnouncer()
    @State private var raceHistory = RaceHistoryStore()
    @State private var osdLayout = OSDLayoutSettings()

    init() {
        UserDefaults.standard.register(defaults: [
            "raceSessionLimit": 90,
            EditorialTheme.accentHueStorageKey: EditorialTheme.defaultAccentHue,
            "targetLapCount": RaceMetrics.defaultTargetLapCount,
            LapAnnouncerDefaults.enabledKey: LapAnnouncerDefaults.defaultEnabled,
            LapAnnouncerDefaults.languageKey: LapAnnouncerDefaults.defaultLanguageRaw,
            LapAnnouncerDefaults.announceBestKey: LapAnnouncerDefaults.defaultAnnounceBest,
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
                .environment(raceHistory)
                .environment(osdLayout)
        }
    }
}
