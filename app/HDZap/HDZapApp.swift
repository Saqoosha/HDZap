import SwiftUI

@main
struct HDZapApp: App {
    @State private var bluetoothManager = BluetoothManager()
    @State private var lapTimer = LapTimer()
    @State private var lapAnnouncer = LapAnnouncer()
    @State private var raceHistory = RaceHistoryStore()
    @State private var osdLayout = OSDLayoutSettings()
    /// One subscription manager shared across the whole app. The init triggers
    /// `Transaction.updates` listener registration via `start()` in onAppear — see body.
    @State private var subscription = SubscriptionManager()

    init() {
        UserDefaults.standard.register(defaults: [
            RaceMetrics.raceSessionLimitStorageKey: RaceMetrics.defaultSessionLimit,
            EditorialTheme.accentHueStorageKey: EditorialTheme.defaultAccentHue,
            RaceMetrics.targetLapCountStorageKey: RaceMetrics.defaultTargetLapCount,
            LapAnnouncerDefaults.enabledKey: LapAnnouncerDefaults.defaultEnabled,
            LapAnnouncerDefaults.languageKey: LapAnnouncerDefaults.defaultLanguageRaw,
            LapAnnouncerDefaults.announceBestKey: LapAnnouncerDefaults.defaultAnnounceBest,
            LapAnnouncerDefaults.rateKey: Double(LapAnnouncerDefaults.defaultRate),
            LapAnnouncerDefaults.pitchKey: Double(LapAnnouncerDefaults.defaultPitch),
            LapAnnouncerDefaults.voiceIdentifierKey: LapAnnouncerDefaults.defaultVoiceIdentifier,
            LapAnnouncerDefaults.countdownEnabledKey: LapAnnouncerDefaults.defaultCountdownEnabled,
            LapAnnouncerDefaults.countdownStartSecondsKey: LapAnnouncerDefaults.defaultCountdownStartSeconds,
            LapAnnouncerDefaults.engineKey: LapAnnouncerDefaults.defaultEngine,
            LapAnnouncerDefaults.premiumVoiceIdentifierKey: LapAnnouncerDefaults.defaultPremiumVoiceIdentifier,
            LapAnnouncerDefaults.premiumRateKey: LapAnnouncerDefaults.defaultPremiumRate,
            LapAnnouncerDefaults.premiumPitchKey: LapAnnouncerDefaults.defaultPremiumPitch,
        ])
        #if DEBUG
        // Screenshot-mode override: force the session-limit + target-lap
        // defaults so the seeded LapTimer / history records always render
        // against the documented 90s / 7L baseline, even on a simulator
        // whose developer previously set different values in Settings.
        // Without this, the @AppStorage backing values would survive and
        // make the screenshot drift from what docs/screenshot-capture.md
        // promises.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-screenshotTimer") || args.contains("-screenshotHistory") {
            UserDefaults.standard.set(RaceMetrics.defaultSessionLimit,
                                      forKey: RaceMetrics.raceSessionLimitStorageKey)
            UserDefaults.standard.set(RaceMetrics.defaultTargetLapCount,
                                      forKey: RaceMetrics.targetLapCountStorageKey)
        }
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
                .environment(subscription)
                .task {
                    // Start the StoreKit2 listener once the SwiftUI scene is on screen — earlier
                    // (e.g. in the App init) would risk firing before the audio session /
                    // BLE permissions are ready, which can spew "transaction observer not
                    // attached in time" warnings on first launch.
                    subscription.start()
                }
        }
    }
}
