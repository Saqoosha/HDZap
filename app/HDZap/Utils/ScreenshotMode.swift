#if DEBUG
import Foundation
import os

/// Launch-arg-driven deep-link routes used to auto-open Settings sub-views
/// for manual / marketing screenshot capture. The model layer (BluetoothManager,
/// SubscriptionManager) checks `ScreenshotMode.isActive` and the relevant
/// route to seed fake state (connected M5Stick, entitled Premium, etc.) so
/// the captured screen reads as a real, populated UI rather than the empty
/// post-fresh-install state the simulator boots into.
///
/// Routes are passed via a single launch arg: `-screenshotRoute <name>`.
/// The view layer reads `ScreenshotMode.route` on first appear and pushes
/// the matching destination programmatically.
///
/// See docs/screenshot-capture.md for the end-to-end procedure.
enum ScreenshotRoute: String {
    /// Settings root with the bridge ON and a connected M5StickS3 — shows
    /// every drilldown populated.
    case settingsRoot

    /// Settings root with bridge OFF — shows the "Connect a bridge to mirror
    /// lap times" hint, the standalone-mode default for fresh installs.
    case settingsRootStandalone

    /// Settings root with bridge ON but no live link (status dot empty,
    /// no battery %). Mirrors the first moment after a user flips the
    /// **Use bridge** toggle on but hasn't tapped **Scan** yet — used by
    /// the §5 step "tap M5StickS3 to drill into the connection screen".
    case settingsRootBridgeOnUnconnected

    /// Settings root scrolled to the very bottom so the **About** card
    /// (App version + Firmware) is fully on-screen. iOS 26.5 added
    /// vertical padding that pushes About below the iPhone 16 Plus
    /// viewport on the default scroll position; the bridge-on seeded
    /// state keeps the Firmware row populated.
    case settingsRootAbout

    /// Lap announcer (System engine) — voice + rate + pitch + countdown.
    case audio

    /// Lap announcer with the "Count down final seconds" toggle ON so the
    /// "Start at" stepper is visible. Used by the §11 (and §10 cross-ref)
    /// Settings reference to show the countdown sub-control.
    case audioCountdownOn

    /// Lap announcer (Premium engine, entitled). Shows the Premium voice
    /// drilldown row, per-provider rate/pitch sliders for the picked voice.
    case audioPremium

    /// Premium voice picker (entitled). The catalog grouped by provider.
    case premiumVoicePicker

    /// Premium voice picker (NOT entitled). Shows the "subscribers only"
    /// CTA banner at the top.
    case premiumVoicePickerLocked

    /// Paywall sheet — the "Subscribe" surface a non-entitled user lands on
    /// when committing a Premium voice choice.
    case paywall

    /// Device → M5StickS3 connection screen, with a connected fake device.
    case connection

    /// Device → M5StickS3 → Rename device. Reached by drilling into
    /// connection then tapping the Bluetooth name row.
    case rename

    /// Device → Goggle pairing screen, Bind Phrase mode (the default).
    case pairing

    /// Pairing screen with the Manual UID mode selected.
    case pairingManualUID

    /// Pairing screen with the New Pairing mode selected.
    case pairingNewPairing

    /// Pairing screen showing the green "Pairing works" success banner —
    /// used by §6 to illustrate what a successful bind looks like.
    case pairingSuccess

    /// Device → OSD layout screen (works standalone, no BLE seed needed).
    case osdLayout

    /// Main timer in the pre-race READY state — no laps recorded, primary
    /// button reads START, masthead shows READY. Used by the §8 manual
    /// section to show what a fresh race screen looks like.
    case timerReady

    /// Main timer with a session in progress and four laps recorded.
    /// Live VBAT strip is populated. (Existing `-screenshotTimer` arg
    /// covers the same shape; this is the route-driven equivalent kept
    /// here so all manual screenshots flow through one mechanism.)
    case timerRunning

    /// Main timer after the race ended — primary button is RESET, results
    /// summary visible, share button enabled. Used by §8 (the FINAL/STOP
    /// outcome) and §9 (what you see right before tapping share).
    case timerDone

    /// History sheet listing past races. Same as `-screenshotHistory`.
    case historyList

    /// History sheet drilled into a specific past race's detail view.
    /// Shows the per-lap table + the VBAT chart (used by both §7 and §9).
    case historyDetail
}

@MainActor
enum ScreenshotMode {
    /// The parsed route from the `-screenshotRoute <name>` launch arg, or nil
    /// when the app was started without one. Computed once and cached so
    /// repeated reads across the view tree return the same value.
    static let route: ScreenshotRoute? = parseRoute()

    /// True iff any of the screenshot launch args (`-screenshotRoute`,
    /// `-screenshotTimer`, `-screenshotHistory`) are present. Used by model
    /// init paths that want to short-circuit BLE permission prompts, network
    /// fetches, and other real-world side effects.
    static var isActive: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-screenshotTimer")
            || args.contains("-screenshotHistory")
            || args.contains("-screenshotRoute")
    }

    /// True when the route implies a "subscriber" state — drives
    /// SubscriptionManager.seedEntitledForScreenshot() so paywall-gated UI
    /// renders the entitled form.
    static var wantsEntitled: Bool {
        switch route {
        case .audioPremium, .premiumVoicePicker:
            return true
        default:
            return false
        }
    }

    /// True when the route implies a "bridge ON + connected" state — drives
    /// BluetoothManager.seedConnectedForScreenshot() so the Settings root
    /// and Connection sub-view render against a populated device row instead
    /// of "Not connected".
    static var wantsConnectedBridge: Bool {
        switch route {
        case .settingsRoot, .settingsRootAbout,
             .connection, .rename, .pairing,
             .pairingManualUID, .pairingNewPairing, .pairingSuccess,
             .osdLayout:
            return true
        default:
            return false
        }
    }

    /// True when the route wants the bridge toggle ON but no live
    /// connection — `seedBridgeEnabledOnly()` in BluetoothManager flips
    /// the toggle without seeding `isConnected`, so the Settings root
    /// shows all three drilldowns but the M5StickS3 row reads "Not
    /// connected" instead of "HDZapBridge · 78 %". Mirrors what a fresh
    /// user sees right after enabling the bridge for the first time.
    static var wantsBridgeOnUnconnected: Bool {
        route == .settingsRootBridgeOnUnconnected
    }

    /// True when the route is one of the timer / history screens. Those
    /// captures should run in standalone mode (bridge OFF) so the
    /// masthead doesn't show the red "Not connected. Tap Scan and
    /// reconnect." banner that fires whenever the bridge is enabled but
    /// has no live link — which is always the case in the simulator.
    static var wantsStandaloneBridge: Bool {
        switch route {
        case .settingsRootStandalone,
             .timerReady, .timerRunning, .timerDone,
             .historyList, .historyDetail:
            return true
        default:
            return false
        }
    }

    private static func parseRoute() -> ScreenshotRoute? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-screenshotRoute"),
              i + 1 < args.count else { return nil }
        let raw = args[i + 1]
        if let route = ScreenshotRoute(rawValue: raw) {
            return route
        }
        // Unknown route name (typo or a removed case the operator's
        // capture script still references). `isActive` will still return
        // true — that suppresses RaceHistoryStore disk loads and hides
        // dev panels — but `route == nil` means no auto-navigation
        // happens, leaving the operator with a half-broken state and no
        // visible signal. Log the bad value so they can correct it.
        let log = Logger(subsystem: "sh.saqoo.HDZap", category: "ScreenshotMode")
        log.error("Unknown -screenshotRoute value: \(raw, privacy: .public)")
        return nil
    }
}
#endif
