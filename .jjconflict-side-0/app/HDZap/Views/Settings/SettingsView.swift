import SwiftUI

/// Settings root: error banner, connection status card, Race controls
/// (kept inline because they're changed every session), and drilldown
/// rows for the device-side and app-side configuration screens. The
/// pairing / connection / audio / appearance bodies live in their own
/// sub-views under Views/Settings/ to keep the root short and to give
/// each domain room for its own conditional UI.
struct SettingsView: View {
    @Environment(BluetoothManager.self) private var bluetooth
    @Environment(OSDLayoutSettings.self) private var layout
    @Environment(\.dismiss) private var dismiss

    @AppStorage(RaceMetrics.targetLapCountStorageKey) private var targetLapCount
        = RaceMetrics.defaultTargetLapCount
    @AppStorage(RaceMetrics.raceSessionLimitStorageKey) private var raceSessionLimit: Int
        = RaceMetrics.defaultSessionLimit
    @AppStorage(EditorialTheme.accentHueStorageKey) private var accentHue: Double
        = EditorialTheme.defaultAccentHue
    @AppStorage(LapAnnouncerDefaults.enabledKey) private var lapTTSEnabled
        = LapAnnouncerDefaults.defaultEnabled
    @AppStorage(LapAnnouncerDefaults.languageKey) private var ttsLanguageRaw
        = LapAnnouncerDefaults.defaultLanguageRaw

    var body: some View {
        NavigationStack {
            List {
                errorSection
                statusSection
                raceSection
                deviceSection
                appSection
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                clampTargetLapCountSetting()
            }
        }
    }

    // MARK: - Error

    /// Same intent as the masthead error strip: keep `remaining` and
    /// `suppressed` separate so neither renders a misleading `0` when only
    /// the other is non-zero. Format matches `TimerView.errorSummaryLine`
    /// — both banners reach the same user, so the strings should not drift.
    private func errorBacklogLine(remaining: Int, suppressed: Int) -> String {
        var parts: [String] = []
        if remaining > 0 { parts.append(String(localized: "+\(remaining) more queued")) }
        if suppressed > 0 { parts.append(String(localized: "+\(suppressed) suppressed")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var errorSection: some View {
        if let err = bluetooth.lastError {
            let remaining = max(bluetooth.errorLog.count - 1, 0)
            let suppressed = bluetooth.droppedErrorCount
            Section("Error") {
                Text(err).foregroundStyle(.red)
                if remaining > 0 || suppressed > 0 {
                    Text(errorBacklogLine(remaining: remaining, suppressed: suppressed))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button(remaining > 0 ? "Next" : "Clear") { bluetooth.clearError() }
                    if remaining > 0 || suppressed > 0 {
                        Spacer()
                        Button("Clear all", role: .destructive) {
                            bluetooth.clearAllErrors()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Status card

    /// Compact connection summary — name + battery percent on one line,
    /// tap-through to the full Connection screen. Mirrors the Apple
    /// Settings "Wi-Fi · MyNetwork" pattern: a single row with the
    /// current state on the right, a chevron to the configuration
    /// screen.
    private var statusSection: some View {
        Section {
            NavigationLink {
                ConnectionSettingsView()
            } label: {
                HStack(spacing: 10) {
                    statusDot
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connection")
                        Text(statusSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        if bluetooth.isConnected {
            Circle().fill(.green).frame(width: 10, height: 10)
        } else {
            Circle().stroke(.secondary, lineWidth: 1).frame(width: 10, height: 10)
        }
    }

    private var statusSubtitle: String {
        guard bluetooth.isConnected, let name = bluetooth.connectedDeviceName else {
            return String(localized: "Not connected")
        }
        guard let raw = bluetooth.batteryPercent else { return name }
        let pct = Int(raw)
        if bluetooth.isCharging {
            return String(localized: "\(name) · \(pct)% · Charging")
        }
        return String(localized: "\(name) · \(pct)%")
    }

    // MARK: - Race (inline — most-changed)

    private var raceSection: some View {
        // Hoisted out of the Text(...) so the formula is greppable and
        // easy to tweak without parsing a deeply-nested call chain.
        let pace = RaceMetrics.seconds(
            RaceMetrics.targetLapSeconds(for: targetLapCount,
                                         sessionLimit: TimeInterval(raceSessionLimit)),
            decimals: 2)
        return Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Race time")
                    Spacer()
                    Text("\(raceSessionLimit)s")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { Double(raceSessionLimit) },
                        set: { raceSessionLimit = Int($0.rounded()) }
                    ),
                    in: Double(RaceMetrics.minSessionLimit)...Double(RaceMetrics.maxSessionLimit),
                    step: Double(RaceMetrics.sessionLimitStep)
                )
            }

            Stepper(value: $targetLapCount,
                    in: RaceMetrics.minTargetLapCount...RaceMetrics.maxTargetLapCount) {
                HStack {
                    Text("Target lap")
                    Spacer()
                    Text("\(RaceMetrics.clampedTargetLapCount(targetLapCount))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            HStack {
                Text("Target pace")
                Spacer()
                Text("\(pace)s")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } header: {
            Text("Race")
        } footer: {
            Text("Target pace is race time ÷ (target lap − 1).")
                .font(.caption2)
        }
    }

    // MARK: - Drilldowns

    private var deviceSection: some View {
        Section("Device") {
            NavigationLink {
                PairingSettingsView()
            } label: {
                LabeledContent("Goggle pairing") {
                    Text(pairingSummary)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            NavigationLink {
                OSDLayoutSettingsView()
            } label: {
                LabeledContent("OSD layout") {
                    Text(osdLayoutSummary)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private var appSection: some View {
        Section("App") {
            NavigationLink {
                AudioSettingsView()
            } label: {
                LabeledContent("Lap announcer") {
                    Text(audioSummary)
                        .foregroundStyle(.secondary)
                }
            }
            NavigationLink {
                AppearanceSettingsView()
            } label: {
                LabeledContent("Appearance") {
                    Circle()
                        .fill(EditorialTheme.accent(hue: accentHue))
                        .frame(width: 14, height: 14)
                }
            }
        }
    }

    // MARK: - Drilldown summaries

    /// Hex form (`60:D2:53:8A:B2:00`) — compact and matches the form the
    /// pairing screen surfaces. Decimal would be longer and crowd the
    /// row's right edge.
    private var pairingSummary: String {
        guard let uid = bluetooth.currentUID else { return String(localized: "—") }
        return formatUID(uid)
    }

    private var osdLayoutSummary: String {
        let snap = layout.snapshot
        guard let bottom1 = snap.visibleBottomRow1Indexed else {
            return String(localized: "All hidden")
        }
        let top1 = snap.firstVisibleRow + 1
        if top1 == bottom1 {
            return String(localized: "Row \(top1)")
        }
        return String(localized: "Rows \(top1)–\(bottom1)")
    }

    private var audioSummary: String {
        if !lapTTSEnabled { return String(localized: "Off") }
        let lang = LapAnnouncerLanguage(rawValue: ttsLanguageRaw) ?? .english
        return String(localized: "On · \(lang.displayName)")
    }

    // MARK: - Helpers

    private func clampTargetLapCountSetting() {
        let clamped = RaceMetrics.clampedTargetLapCount(targetLapCount)
        if targetLapCount != clamped {
            targetLapCount = clamped
        }
    }
}
