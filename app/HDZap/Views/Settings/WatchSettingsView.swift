import SwiftUI

/// Catalogue of every built-in `WKHapticType` exposed by watchOS,
/// keyed by the raw name the watch-side `RaceCoordinator` switches
/// on. Defined here on the iPhone side so the Settings UI stays free
/// of any `WatchKit` import — the iPhone target doesn't link WatchKit
/// at all.
private struct TestHapticOption: Identifiable {
    let name: String
    let label: String
    let blurb: String
    var id: String { name }
}

private let testHapticOptions: [TestHapticOption] = [
    .init(name: "notification",  label: "Notification",   blurb: "Standard firm tap"),
    .init(name: "directionUp",   label: "Direction Up",   blurb: "Single tap, upward feel"),
    .init(name: "directionDown", label: "Direction Down", blurb: "Single tap, downward feel"),
    .init(name: "success",       label: "Success",        blurb: "Built-in ascending trill"),
    .init(name: "retry",         label: "Retry",          blurb: "Rapid alternating pulses"),
    .init(name: "failure",       label: "Failure",        blurb: "Long alarm (~1.5 s)"),
    .init(name: "start",         label: "Start",          blurb: "Affirmative single tap"),
    .init(name: "stop",          label: "Stop",           blurb: "Distinct single tap"),
    .init(name: "click",         label: "Click",          blurb: "Subtle quick click"),
]

/// Apple Watch countdown haptics — toggle + status. Lives under the
/// Settings root's "App" section.
///
/// Subscription gate: the feature is HDZap Premium. Non-entitled
/// operators see a paywall card in place of the toggle and the
/// Try-haptics audition section; the underlying `WatchHapticsDefaults`
/// toggle is auto-cleared by `TimerView`'s entitlement-lapse handler
/// so the storage value can't drift "on" while the entitlement is
/// gone. Mirrors the gating pattern used by Premium TTS in
/// `AudioSettingsView`.
///
/// Status copy is derived from `WatchBridge`'s pairing/installation/
/// reachability flags. The toggle stores into `WatchHapticsDefaults`,
/// which `TimerView` mirrors into `RaceSnapshot.hapticsEnabled` on the
/// next publish — the watch obeys that field rather than keeping its
/// own copy, so toggling here takes effect on the wrist immediately.
struct WatchSettingsView: View {
    @Environment(WatchBridge.self) private var bridge
    @Environment(SubscriptionManager.self) private var subscription

    @AppStorage(WatchHapticsDefaults.enabledKey) private var enabled
        = WatchHapticsDefaults.defaultEnabled

    @State private var showingPaywall = false

    var body: some View {
        Form {
            if subscription.isEntitled {
                toggleSection
            } else {
                paywallSection
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

            // Try-haptics audition lives at the bottom and is also
            // gated on entitlement — non-subscribers see the paywall
            // card above, and giving them a haptic audition without
            // the underlying feature would be teasing.
            if subscription.isEntitled {
                tryHapticsSection
            }
        }
        .navigationTitle("Apple Watch")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPaywall) {
            PaywallView()
        }
    }

    // MARK: - Sections

    private var toggleSection: some View {
        Section {
            Toggle("Race countdown haptics", isOn: $enabled)
        } footer: {
            Text("Buzzes the Apple Watch at 30 s (gentle up-tap), 20 s (firm tap), and 10 s remaining (long alarm), plus a double alarm at the buzzer.")
                .font(.caption2)
        }
    }

    /// Premium upsell card. Replaces the toggle section for non-
    /// entitled operators — the entitled toggle never appears here, so
    /// there's no "tap-on then bounce-to-paywall" footgun.
    private var paywallSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "applewatch.radiowaves.left.and.right")
                        .font(.title3)
                        .foregroundStyle(.tint)
                    Text("Race countdown haptics")
                        .font(.subheadline.bold())
                    Spacer()
                    Text("Premium")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule())
                        .foregroundStyle(.tint)
                }
                Text("Distinct haptic patterns at 30 s, 20 s, and 10 s remaining — so you feel which mark just fired without looking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    showingPaywall = true
                } label: {
                    Text("Subscribe to enable")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
            .padding(.vertical, 4)
        } footer: {
            Text("HDZap Premium also includes cloud Premium voices for the lap announcer.")
                .font(.caption2)
        }
    }

    /// Lives at the bottom so it doesn't push the main toggle and
    /// status rows below the fold. Buttons are disabled when the
    /// watch isn't reachable — the iPhone uses `sendMessage` for
    /// one-shot haptic auditions, which requires the watch app to be
    /// foregrounded (or running a workout). Footer explains the
    /// disabled state so the operator isn't left wondering.
    private var tryHapticsSection: some View {
        Section {
            ForEach(testHapticOptions) { opt in
                Button {
                    bridge.sendTestHaptic(typeName: opt.name)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(opt.label)
                            .foregroundStyle(.primary)
                        Text(opt.blurb)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!bridge.isReachable)
            }
        } header: {
            Text("Try haptics")
        } footer: {
            Text(bridge.isReachable
                 ? "Tap any row to feel that pattern on your wrist."
                 : "Open the HDZap app on your Apple Watch to enable these — auditioning a haptic needs the watch app reachable.")
                .font(.caption2)
        }
    }

    // MARK: - Status derivations

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
    /// matters — entitlement gate first (no point telling the operator
    /// to install the watch app if they aren't subscribed), then
    /// pairing preconditions, then arming.
    private var armingHint: String {
        if !subscription.isEntitled {
            return String(localized: "Subscribe to HDZap Premium to enable Apple Watch countdown haptics.")
        }
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
