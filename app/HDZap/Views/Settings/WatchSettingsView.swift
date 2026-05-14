import SwiftUI

/// Apple Watch countdown haptics — toggle + status. Lives under the
/// Settings root's "App" section.
///
/// Status copy is derived from `WatchBridge`'s pairing/installation/
/// reachability flags. The toggle stores into `WatchHapticsDefaults`,
/// which `TimerView` mirrors into `RaceSnapshot.hapticsEnabled` on the
/// next publish — the watch obeys that field rather than keeping its
/// own copy, so toggling here takes effect on the wrist immediately.
struct WatchSettingsView: View {
    @Environment(WatchBridge.self) private var bridge

    @AppStorage(WatchHapticsDefaults.enabledKey) private var enabled
        = WatchHapticsDefaults.defaultEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Race countdown haptics", isOn: $enabled)
            } footer: {
                Text("Buzzes the Apple Watch at 30 s (single tap), 20 s (double), and 10 s (triple) remaining, plus a long tap at the buzzer.")
                    .font(.caption2)
            }

            Section("Status") {
                LabeledContent("Watch") {
                    Text(pairingStatus)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                LabeledContent("App") {
                    Text(appStatus)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                LabeledContent("Reachable") {
                    Text(bridge.isReachable ? "Yes" : "No")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }

            Section {
                EmptyView()
            } footer: {
                Text(armingHint)
                    .font(.caption2)
            }
        }
        .navigationTitle("Apple Watch")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var pairingStatus: String {
        if !bridge.isSupported { return String(localized: "Unsupported device") }
        return bridge.isPaired ? String(localized: "Paired") : String(localized: "Not paired")
    }

    private var appStatus: String {
        guard bridge.isPaired else { return "—" }
        return bridge.isWatchAppInstalled
            ? String(localized: "Installed")
            : String(localized: "Not installed")
    }

    /// Single-line guidance whose text reflects the next action the
    /// operator needs to take to actually feel the haptics. Order
    /// matters — "open the watch app" only makes sense once installed,
    /// and installing only makes sense once paired.
    private var armingHint: String {
        if !bridge.isSupported {
            return String(localized: "Apple Watch isn't supported on this device.")
        }
        if !bridge.isPaired {
            return String(localized: "Pair an Apple Watch in the Watch app on iPhone.")
        }
        if !bridge.isWatchAppInstalled {
            return String(localized: "Install the HDZap watch app from the Watch app on iPhone.")
        }
        if !enabled {
            return String(localized: "Turn on Race countdown haptics above to arm the watch.")
        }
        if !bridge.isReachable {
            return String(localized: "Open the HDZap app on your Apple Watch and start a race to arm haptics. The watch starts a workout session for the duration of the race so countdown taps fire reliably.")
        }
        return String(localized: "Ready. Start a race on iPhone — the watch will buzz at 30, 20, and 10 seconds remaining.")
    }
}
