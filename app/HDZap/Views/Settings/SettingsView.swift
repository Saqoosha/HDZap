import SwiftUI

/// Settings root: error banner, Format controls (race time + target
/// lap, kept inline because they change every session), Device
/// drilldowns (M5StickS3 status row + Goggle pairing + OSD layout),
/// and App drilldowns (Lap announcer + Appearance). Each sub-view
/// lives in its own file under Views/Settings/ to keep the root short
/// and to give each domain room for its own conditional UI.
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
    @AppStorage(WatchHapticsDefaults.enabledKey) private var watchHapticsEnabled
        = WatchHapticsDefaults.defaultEnabled
    @Environment(WatchBridge.self) private var watchBridge
    @Environment(SubscriptionManager.self) private var subscription

    var body: some View {
        NavigationStack {
            List {
                errorSection
                raceSection
                deviceSection
                appSection
                #if DEBUG
                debugSection
                #endif
                aboutSection
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

    // MARK: - Status helpers (used by the M5StickS3 row in deviceSection)

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

    // MARK: - Format (race time + target lap; inline — most-changed)

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
            Text("Format")
        } footer: {
            Text("Target pace is race time ÷ (target lap − 1).")
                .font(.caption2)
        }
    }

    // MARK: - Drilldowns

    private var deviceSection: some View {
        // "Use bridge" toggle leads the section so users without an
        // M5StickS3 see one row instead of three. The toggle owns the
        // lazy `CBCentralManager` lifecycle — flipping it on is the
        // moment iOS first asks for Bluetooth permission, so users who
        // don't own the hardware never see that prompt. The three
        // drilldowns (M5StickS3 status, Goggle pairing, OSD layout)
        // hide when the toggle is off; the footer hint replaces them
        // so the section doesn't read as "nothing to do here".
        Section {
            Toggle(isOn: Binding(
                get: { bluetooth.isBridgeEnabled },
                set: { bluetooth.setBridgeEnabled($0) }
            )) {
                Text("Use bridge")
            }
            if bluetooth.isBridgeEnabled {
                // M5StickS3 row: same two-line Apple-Settings shape as
                // before (status dot + name/battery), drills into
                // scan / Disconnect / discovered list.
                NavigationLink {
                    ConnectionSettingsView()
                } label: {
                    HStack(spacing: 10) {
                        statusDot
                        VStack(alignment: .leading, spacing: 2) {
                            Text("M5StickS3")
                            Text(statusSubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
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
        } header: {
            Text("Device")
        } footer: {
            if !bluetooth.isBridgeEnabled {
                Text("Connect an M5Stick bridge to mirror lap times on your goggle OSD.")
                    .font(.caption2)
            }
        }
    }

    #if DEBUG
    /// Debug-build-only section. Surfaces the orphaned
    /// `BackpackTelemetryDebugView` and the in-development voltage chart
    /// preview so layout / wiring can be verified without scaffolding.
    /// Wrapped in `#if DEBUG` so release builds never ship the entry.
    /// The BackpackTelemetryDebugView entry is additionally gated on
    /// `isBridgeEnabled` so a debug build with the bridge toggled off
    /// can't reach a BLE-write surface — same contract as the
    /// drilldowns in `deviceSection`. The voltage-chart preview is
    /// UI-only and stays visible.
    @ViewBuilder
    private var debugSection: some View {
        Section("Debug") {
            if bluetooth.isBridgeEnabled {
                NavigationLink {
                    BackpackTelemetryDebugView()
                } label: {
                    Text("Backpack telemetry")
                }
            }
            NavigationLink {
                RaceDetailView(previewRecord: VoltageChartPreview.sampleRecord())
            } label: {
                Text("Voltage chart preview")
            }
        }
    }
    #endif

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
                WatchSettingsView()
            } label: {
                LabeledContent("Apple Watch") {
                    Text(watchSummary)
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

    /// Same condensed-status pattern as `audioSummary` — "Off" when the
    /// toggle is off; otherwise a one-word state derived from the
    /// bridge so the row reflects whether the next race will actually
    /// reach the wrist or fall on the floor. Non-subscribers see
    /// "Premium" — the drilldown handles the upsell.
    private var watchSummary: String {
        if !subscription.isEntitled { return String(localized: "Premium") }
        if !watchHapticsEnabled { return String(localized: "Off") }
        if !watchBridge.isPaired { return String(localized: "On · No watch") }
        if !watchBridge.isWatchAppInstalled { return String(localized: "On · App missing") }
        if !watchBridge.isReachable { return String(localized: "On · Not armed") }
        return String(localized: "On · Armed")
    }

    // MARK: - About (app + firmware version, glanceable from root)

    /// At-a-glance app and firmware version row. Same source of truth as
    /// the version row inside `ConnectionSettingsView`, but lives on the
    /// Settings root so the operator can confirm the pair before drilling
    /// into M5StickS3. Firmware row is hidden until a connect-time read
    /// has landed (`bluetooth.firmwareVersion != nil`); when the firmware
    /// reports a major that disagrees with the app, both this row's
    /// trailing text and the inline warning go red — matching the
    /// drilldown so the two surfaces never disagree on what's wrong.
    private var aboutSection: some View {
        let appVersion = BluetoothManager.appVersionString() ?? "?"
        return Section("About") {
            LabeledContent("App version") {
                Text(appVersion)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let fw = bluetooth.firmwareVersion {
                LabeledContent("Firmware") {
                    Text(fw)
                        .font(.caption.monospaced())
                        .foregroundStyle(bluetooth.firmwareIncompatible ? .red : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if bluetooth.firmwareIncompatible {
                    Text(BluetoothManager.firmwareMismatchSummary)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Drilldown summaries

    /// Decimal form (`96,210,83,138,178,0`) — matches what HDZero
    /// goggles and the M5Stick LCD display, so the operator can compare
    /// the row at a glance against the hardware they're pairing to.
    /// Reads `lastKnownUID` rather than `currentUID` so a fresh app
    /// launch surfaces the remembered UID immediately, before BLE
    /// reconnects. The Pairing sub-screen's "Current UID" section
    /// stays bound to live `currentUID` for authoritative display.
    private var pairingSummary: String {
        guard let uid = bluetooth.lastKnownUID else { return String(localized: "—") }
        return formatUIDDecimal(uid)
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
