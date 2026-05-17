import SwiftUI
import UIKit
import os

/// Editorial Console — quiet typography, hairline rules, inline sparkbars.
/// Modeled on the iOS Lap Timer handoff prototype (V2 Editorial).
///
/// 90-second time-attack window: count as many laps as possible before the
/// session bar runs out. The lap in flight when 90s passes is the FINAL lap;
/// pressing the primary button records it and ends the session.
struct TimerView: View {
    @Environment(LapTimer.self) private var lapTimer
    @Environment(BluetoothManager.self) private var bluetooth
    @Environment(LapAnnouncer.self) private var announcer
    @Environment(RaceHistoryStore.self) private var history
    @Environment(OSDLayoutSettings.self) private var osdLayout
    @AppStorage(RaceMetrics.targetLapCountStorageKey) private var targetLapCount
        = RaceMetrics.defaultTargetLapCount
    @AppStorage(RaceMetrics.raceSessionLimitStorageKey) private var raceSessionLimit: Int
        = RaceMetrics.defaultSessionLimit
    @AppStorage(LapAnnouncerDefaults.enabledKey) private var lapTTSEnabled
        = LapAnnouncerDefaults.defaultEnabled
    @Environment(\.accentHue) private var accentHue: Double
    private var accent: Color { EditorialTheme.accent(hue: accentHue) }
    private var sessionLimit: TimeInterval { TimeInterval(raceSessionLimit) }

    /// Stable 1Hz publisher for the goggle TIME LEFT row. Declared as
    /// a `let` so the same publisher survives across body re-evaluations
    /// — defining `Timer.publish(...).autoconnect()` inline inside
    /// `.onReceive` re-creates the publisher on every body call, and
    /// SwiftUI may not keep the prior subscription alive, so the tick
    /// silently stops firing. Property scope keeps it pinned for the
    /// view's lifetime.
    private let osdTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    @State private var showSettings = false
    @State private var showHistory = false
    /// Set after the race lands in the history store so a duplicate
    /// `.onChange(of: sessionEnded)` firing — or a manual STOP after a
    /// FINAL-lap save — couldn't insert the same race twice. Cleared on
    /// RESET.
    @State private var savedRaceID: UUID?
    /// CRSF flight-pack battery samples for the in-memory session.
    @State private var raceFlightBatterySamples: [RaceFlightBatterySample] = []
    /// Captured once at the moment a lap is recorded. Kept stable so the
    /// displayed projection/diff doesn't tick every frame as the in-flight
    /// lap consumes the remaining window. Cleared on START and RESET.
    @State private var metricsSnapshot: RaceMetrics?
    /// Set when the user taps STOP with at least one recorded lap so the
    /// view flips to the result/done summary. STOP with no laps just pauses
    /// the timer — no point showing an empty results screen. Cleared by RESET.
    @State private var manuallyEnded = false
    /// True iff the most recently recorded lap took the FINAL branch in
    /// `primaryAction()`. Captured at action time so the haptic closure
    /// doesn't depend on SwiftUI's body re-eval order relative to
    /// `lapTimer.stop()`. Cleared on regular LAP, START, and RESET.
    @State private var lastLapWasFinal = false
    /// Tracks whether the operator explicitly tapped SHOW READY so the
    /// pre-race goggle summary survives a Settings round-trip. Without
    /// this, every Settings/OSD-Layout dismiss would auto-restore the
    /// Ready frame even when the user never asked for it; with it, the
    /// goggle stays blank until SHOW READY is pressed, and Settings
    /// restores Ready only if the user had explicitly enabled it.
    /// Cleared on START (race transitions to running) and RESET (clean
    /// pre-race state again).
    @State private var readyShown = false
    /// Wraps the temp PNG URL so `.sheet(item:)` has an `Identifiable` payload.
    /// Re-rendered on every `shareAction()` because laps and metrics may change
    /// between presentations.
    @State private var shareItem: ShareItem?
    /// Mirrors `shareItem.url` so the temp file can still be deleted in
    /// `.sheet(item:, onDismiss:)` — by the time `onDismiss` fires, SwiftUI
    /// has already nilled out `shareItem`, so we need a separate handle.
    @State private var lastShareURL: URL?
    /// Local error channel for share-flow failures. Kept separate from
    /// `bluetooth.lastError` so a render/save failure isn't mistaken for a
    /// BLE link issue and doesn't pollute the BLE error log/dropped-counter
    /// accounting.
    @State private var shareError: String?

    private var timeUp: Bool { lapTimer.elapsedTime >= sessionLimit }
    private var sessionEnded: Bool {
        manuallyEnded || (!lapTimer.isRunning && timeUp)
    }
    private var remaining: TimeInterval { max(0, sessionLimit - lapTimer.elapsedTime) }
    private var progress: Double { min(1, lapTimer.elapsedTime / sessionLimit) }
    private var bestTime: TimeInterval? {
        guard let i = lapTimer.bestLapIndex else { return nil }
        return lapTimer.laps[i].time
    }
    private var worstTime: TimeInterval? {
        lapTimer.laps.map(\.time).max()
    }
    private var avgTime: TimeInterval {
        guard !lapTimer.laps.isEmpty else { return 0 }
        return lapTimer.laps.reduce(0) { $0 + $1.time } / Double(lapTimer.laps.count)
    }
    private var clampedTargetLapCount: Int {
        RaceMetrics.clampedTargetLapCount(targetLapCount)
    }
    private var targetSummaryValue: String {
        let targetLapSec = RaceMetrics.targetLapSeconds(for: clampedTargetLapCount, sessionLimit: sessionLimit)
        return "\(clampedTargetLapCount)L@\(RaceMetrics.seconds(targetLapSec, decimals: 2))"
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            EditorialTheme.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                masthead

                if let err = bluetooth.lastError {
                    errorStrip(err)
                } else if bluetooth.isBridgeEnabled && !bluetooth.isReady {
                    // Surface link state passively — actions always run
                    // against iOS state, but the operator should know the
                    // goggle won't update until BLE is back. Suppressed
                    // when the bridge is disabled in Settings: users who
                    // don't own the hardware shouldn't see a "Not connected"
                    // nag for a device they're not trying to reach.
                    bleStrip
                }

                ScrollView {
                    VStack(spacing: 0) {
                        // Padding is applied INSIDE the strip's visible
                        // branch so the NO TX hide also removes the
                        // top/bottom margin — otherwise an empty 32-pt
                        // band would sit between the masthead and the
                        // sessionBar with nothing in it.
                        // The bottom margin between the strip and the
                        // sessionBar is owned by the sessionBar's top
                        // padding (20 pt) rather than the strip's
                        // bottom padding so that when the strip hides,
                        // the sessionBar still keeps a comfortable
                        // breathing distance from the masthead.
                        flightBatteryStrip

                        sessionBar
                            .padding(.horizontal, 24)
                            .padding(.top, 20)

                        timerBlock
                            .padding(.horizontal, 24)
                            .padding(.top, 16)
                            .padding(.bottom, 0)

                        summaryBand
                            .padding(.horizontal, 24)

                        lapHeader
                            .padding(.horizontal, 24)
                            .padding(.top, 14)

                        lapRowsWithTrend
                            .padding(.horizontal, 24)
                    }
                    .padding(.bottom, 260) // ActionDock clearance (taller with READY button)
                }
                .scrollIndicators(.hidden)
            }

            actionDock
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showHistory) {
            HistoryView()
        }
        .sheet(item: $shareItem, onDismiss: cleanupShareTempFile) { item in
            ShareSheet(url: item.url)
        }
        .alert(
            "Share Failed",
            isPresented: Binding(
                get: { shareError != nil },
                set: { if !$0 { shareError = nil } }
            ),
            presenting: shareError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
        .onAppear {
            clampTargetLapCountSetting()
            // .onChange(of: bluetooth.isReady) below only fires on
            // transitions, so a TimerView that mounts AFTER an iOS
            // auto-reconnect already settled would otherwise leave the
            // M5Stick on its boot-default bottom-anchored layout. The
            // sendOSDLayout silently no-ops when the layout char hasn't
            // been discovered yet, so this is safe to call unconditionally.
            if bluetooth.isReady {
                _ = bluetooth.sendOSDLayout(yOffset: osdLayout.snapshot.firmwareYOffset)
            }
        }
        .onChange(of: targetLapCount) { _, _ in
            handleTargetLapCountChange()
        }
        .onChange(of: raceSessionLimit) { _, _ in
            // Race time is part of the metric inputs (target pace,
            // remaining-window pace projection). When the operator
            // bumps it after laps already exist, the displayed Diff/
            // Need/Bank and the pre-rendered OSD lines must be
            // recomputed against the new window — otherwise the
            // goggle and the iPhone disagree on the same race.
            refreshMetricsSnapshot()
            sendMetricRows()
        }
        // Refresh just the goggle's TIME LEFT row once a second while a
        // session is in flight. The bottom three rows are sent only on
        // lap record (and on session-limit change), so a tick costs one
        // BLE write and a 2-packet ESP-NOW cycle (writeString + draw).
        // Skip while the Settings sheet is up — explicit operator
        // actions there (Test OSD, Clear OSD, Reset Laps) shouldn't
        // be immediately overwritten by a stale TIME LEFT.
        .onReceive(osdTick) { _ in
            guard lapTimer.isRunning && !sessionEnded && bluetooth.isReady else { return }
            guard !showSettings else { return }
            sendTimeLeftRow()
        }
        // Persist the race once it transitions to ended. `sessionEnded`
        // flips false→true via either the FINAL-lap path or manual STOP
        // with laps. `savedRaceID` guards against accidental double saves
        // if anything else re-evaluates the body while still in the ended
        // state.
        .onChange(of: sessionEnded) { _, ended in
            if ended {
                saveRaceIfNeeded()
                sendResultOSD()
            }
        }
        // Replay the OSD layout Y offset whenever the goggle becomes
        // reachable, then re-paint the live race frame so alignment +
        // visibility (which ride the OSD text path, not the layout
        // char) also land. Firmware doesn't persist any of these (per
        // project decision: iOS owns them), so a fresh boot, deep-sleep
        // wake, or BLE reconnect would otherwise revert to whatever the
        // goggle's overlay buffer last held while iOS still thinks the
        // user's preferred layout is in effect.
        // Skipped while the layout editor is on screen — the editor's
        // own debounced push will repaint with the dummy preview the
        // pilot is editing against, and racing it from here would
        // briefly flash the live race frame onto the goggle just before
        // the editor reasserts its preview.
        .onChange(of: bluetooth.isReady) { _, ready in
            guard ready, !osdLayout.previewEditorActive else { return }
            _ = bluetooth.sendOSDLayout(yOffset: osdLayout.snapshot.firmwareYOffset,
                                        urgent: true)
            flushCurrentRaceFrame()
        }
        // Resync the layout char whenever the user's stored layout
        // changes from outside the editor (currently only `resetToDefaults`
        // can hit this path while the editor is closed). While the editor
        // is active, gate these handlers so they don't double-write the
        // layout char on every slider tick — the editor already debounces
        // its own push onto the same characteristic, so any extra resync
        // from here is purely redundant traffic. `rows` is watched
        // alongside `firstVisibleRow` because changing visibility shifts
        // `firmwareYOffset` (visible-block height determines the buffer's
        // top row).
        .onChange(of: osdLayout.firstVisibleRow) { _, _ in
            guard !osdLayout.previewEditorActive, bluetooth.isReady else { return }
            _ = bluetooth.sendOSDLayout(yOffset: osdLayout.snapshot.firmwareYOffset)
        }
        .onChange(of: osdLayout.rows) { _, _ in
            guard !osdLayout.previewEditorActive, bluetooth.isReady else { return }
            _ = bluetooth.sendOSDLayout(yOffset: osdLayout.snapshot.firmwareYOffset)
        }
        // The moment the layout editor pops, repaint the live race
        // frame over whatever dummy preview rows the editor pushed. The
        // outer Settings sheet often stays open afterward, so deferring
        // to its dismiss alone would leave fake `LAP 3 12.345` etc. on
        // the goggle for the rest of the Settings session.
        .onChange(of: osdLayout.previewEditorActive) { _, active in
            guard !active, bluetooth.isReady else { return }
            // Re-issue the layout char too — the editor may have left
            // the goggle on a different `firmwareYOffset` (e.g. user
            // toggled visibility while there) that the editor's
            // debounce dropped on cancel.
            _ = bluetooth.sendOSDLayout(yOffset: osdLayout.snapshot.firmwareYOffset)
            flushCurrentRaceFrame()
        }
        // Belt-and-braces: if the user closes the Settings sheet
        // without ever entering the layout editor — or the editor's
        // disappear flush somehow missed (notification ordering, etc.)
        // — re-flush on the sheet's true→false transition.
        .onChange(of: showSettings) { _, isOpen in
            guard !isOpen, bluetooth.isReady else { return }
            flushCurrentRaceFrame()
        }
        // Race start: switch the goggle from any prior Ready frame
        // (which uses the all-visible layout variant — different
        // `firmwareYOffset` whenever the user has rows hidden) to the
        // user's in-race partial layout, and pre-clear the slots that
        // partial visibility leaves blank. Without this prelude, the
        // first sendTimeLeftRow tick would route slot indices through
        // the partial buffer math while the goggle still believed it
        // was rendering the all-visible buffer, so TIME LEFT could
        // land on the wrong grid row until the next full push.
        .onChange(of: lapTimer.isRunning) { _, running in
            guard running, bluetooth.isReady else { return }
            pushOSDBuffer(osdLayout.snapshot, semanticRaws: [
                RaceMetrics.timeLeftRaw(remainingSec: remaining), "", "", "",
            ])
            // Capture the current flight-battery reading at race start
            // even when the firmware's change-gate has nothing to push:
            // a steady voltage between flight-pack hot-plug and the
            // race-start tap would otherwise leave the saved race with
            // zero samples until something on the pack changes.
            ingestFlightBatteryTelemetry()
        }
        .onChange(of: bluetooth.flightBatteryNotifyRevision) { _, _ in
            ingestFlightBatteryTelemetry()
        }
        // Haptic on LAP tap. Fires only on count growth so RESET (count → 0)
        // stays silent. `lastLapWasFinal` is set in `primaryAction()` before
        // the lap is recorded — reading `sessionEnded` here would depend on
        // SwiftUI re-evaluating the body after `lapTimer.stop()` flips
        // `isRunning`, which is implementation-dependent.
        .sensoryFeedback(trigger: lapTimer.laps.count) { old, new in
            guard new > old else { return nil }
            return lastLapWasFinal ? .success : .impact(weight: .medium)
        }
        // Haptic on START — fires on the false → true transition only,
        // so STOP (true → false) stays silent. .start is too subtle on
        // device; .impact(.heavy) gives a clear "race begins" thump that's
        // distinct from .impact(.medium) on LAP.
        .sensoryFeedback(trigger: lapTimer.isRunning) { old, new in
            (!old && new) ? .impact(weight: .heavy) : nil
        }
    }

    // MARK: - Masthead

    private var masthead: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Time Attack · \(raceSessionLimit)s")
                .monoCap(size: 9.5, tracking: 2.0)

            Text("•")
                .font(.system(size: 9))
                .foregroundStyle(EditorialTheme.dim)

            HStack(spacing: 6) {
                StatusDot(active: lapTimer.isRunning && !sessionEnded,
                          color: timeUp ? accent : (lapTimer.isRunning ? accent : EditorialTheme.dim))
                Text(stateLabel)
                    .monoCap(size: 9.5, tracking: 1.5,
                             color: timeUp ? accent : EditorialTheme.sub)
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    showHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(EditorialTheme.ink)
                        .frame(width: 30, height: 30)
                        .background(EditorialTheme.ink.opacity(0.06), in: Circle())
                }
                .accessibilityLabel("History")

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(EditorialTheme.ink)
                        .frame(width: 30, height: 30)
                        .background(EditorialTheme.ink.opacity(0.06), in: Circle())
                }
                .accessibilityLabel("Settings")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    /// Compose a short status line about the error backlog. Keeps the two
    /// counters separate so e.g. `suppressed > 0, queued == 0` doesn't render
    /// as a misleading `"+0 more queued"`.
    private func errorSummaryLine(queued: Int, suppressed: Int) -> String {
        var parts: [String] = []
        if queued > 0 { parts.append(String(localized: "+\(queued) more queued")) }
        if suppressed > 0 { parts.append(String(localized: "+\(suppressed) suppressed")) }
        return parts.joined(separator: " · ")
    }

    private var stateLabel: String {
        if sessionEnded { return "DONE" }
        if timeUp && lapTimer.isRunning { return "FINAL LAP" }
        return lapTimer.isRunning ? "LIVE" : "PAUSED"
    }

    private func errorStrip(_ message: String) -> some View {
        let queued = max(bluetooth.errorLog.count - 1, 0)
        let suppressed = bluetooth.droppedErrorCount
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .font(.editorialMono(10, weight: .regular))
                    .foregroundStyle(EditorialTheme.ink)
                    .lineLimit(2)
                if queued > 0 || suppressed > 0 {
                    let summary = errorSummaryLine(queued: queued, suppressed: suppressed)
                    Text(summary)
                        .monoCap(size: 8.5, tracking: 1.4, color: EditorialTheme.sub)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Button(queued > 0 ? "NEXT" : "DISMISS") { bluetooth.clearError() }
                    .monoCap(size: 9, tracking: 1.4, color: EditorialTheme.sub)
                    .buttonStyle(.plain)
                if queued > 0 || suppressed > 0 {
                    Button("CLEAR ALL") { bluetooth.clearAllErrors() }
                        .monoCap(size: 8.5, tracking: 1.4, color: EditorialTheme.dim)
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(accent.opacity(0.08))
        .overlay(alignment: .bottom) {
            Rectangle().fill(EditorialTheme.hair).frame(height: 0.5)
        }
    }

    private var bleStrip: some View {
        HStack(spacing: 8) {
            StatusDot(active: false, color: EditorialTheme.dim)
            Text("BLE OFF · Laps won't reach the goggle")
                .monoCap(size: 9, tracking: 1.4, color: EditorialTheme.sub)
            Spacer()
            Button("OPEN") { showSettings = true }
                .monoCap(size: 9, tracking: 1.4, color: EditorialTheme.ink)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
        .background(EditorialTheme.ink.opacity(0.04))
        .overlay(alignment: .bottom) {
            Rectangle().fill(EditorialTheme.hair).frame(height: 0.5)
        }
    }

    // MARK: - Session bar

    private var sessionBar: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Elapsed").monoCap(size: 10, tracking: 1.5)
                    Text(EditorialFormat.time(lapTimer.elapsedTime, msDigits: 2))
                        .font(.editorialMono(18, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(EditorialTheme.ink)
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Remain").monoCap(size: 10, tracking: 1.5)
                    Text(EditorialFormat.time(remaining, msDigits: 2))
                        .font(.editorialMono(18, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(timeUp ? accent : EditorialTheme.ink)
                }
            }

            ZStack(alignment: .leading) {
                // Track
                Rectangle()
                    .fill(EditorialTheme.ink.opacity(0.06))
                    .overlay(alignment: .top) {
                        Rectangle().fill(EditorialTheme.ink).frame(height: 1)
                    }
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(EditorialTheme.hair).frame(height: 0.5)
                    }

                // Tick marks every 10s — count derived from the
                // configured race time so 60/90/120/180s all read
                // "every 10s" rather than "evenly spaced 8 ticks".
                GeometryReader { geo in
                    ForEach(Array(stride(from: 10, to: raceSessionLimit, by: 10)), id: \.self) { sec in
                        Rectangle()
                            .fill(EditorialTheme.hairStrong)
                            .frame(width: 1)
                            .offset(x: geo.size.width * Double(sec) / Double(raceSessionLimit))
                    }
                }

                // Fill
                GeometryReader { geo in
                    Rectangle()
                        .fill(accent)
                        .frame(width: max(0, geo.size.width * progress))
                        .animation(.linear(duration: 0.08), value: progress)

                    // Leading-edge cursor
                    TimelineView(.periodic(from: .now, by: 0.45)) { ctx in
                        let pulsing = lapTimer.isRunning && progress < 1
                        let beat = Int(ctx.date.timeIntervalSinceReferenceDate / 0.45) % 2
                        Rectangle()
                            .fill(progress >= 1 ? accent : EditorialTheme.ink)
                            .frame(width: 2)
                            .offset(x: geo.size.width * progress - 1, y: -3)
                            .frame(height: geo.size.height + 6)
                            .opacity(pulsing && beat == 0 ? 0.45 : 1)
                    }
                }
            }
            .frame(height: 14)

            HStack {
                Text("0").monoCap(size: 8.5, tracking: 1.5)
                Spacer()
                Text("\(raceSessionLimit / 2)").monoCap(size: 8.5, tracking: 1.5)
                Spacer()
                Text("\(raceSessionLimit)").monoCap(size: 8.5, tracking: 1.5)
            }
        }
    }

    // MARK: - Flight battery strip

    /// Threshold for flipping a flight-battery reading from LIVE to
    /// STALE. CRSF Battery sensor telemetry rate depends on the
    /// Betaflight `msp_override_channels` / sensor cadence config —
    /// observed values range from ~0.25 Hz (one packet every ~4 s) up
    /// to ~1 Hz with the higher-rate config. 12 s tolerates one
    /// missed packet at the slowest end without false-flipping; at
    /// faster cadences it just gives the operator a generous "did
    /// the link really drop?" margin.
    private static let flightBatteryStaleAfter: TimeInterval = 12

    /// Voltage hero + consumed mAh + remaining-percent label, with a
    /// thin progress bar underneath that mirrors the percent value.
    /// Hidden entirely (paddings included, see body site) when no
    /// telemetry has arrived since BLE connect. `TimelineView(.periodic)`
    /// is the live-vs-stale flip clock — voltages themselves come
    /// directly from `BluetoothManager`'s flight-battery properties,
    /// re-read each tick.
    @ViewBuilder
    private var flightBatteryStrip: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let status = flightBatteryStatus(at: ctx.date)
            // NO TX → strip is hidden entirely (including paddings, see
            // body site). The user wanted no visual placeholder when
            // the radio's LUA telemetry switch is off or the TX is
            // unbound; the strip just disappears until the first
            // packet lands.
            if status != .noTx, let r = flightBatteryReading(at: ctx.date) {
                VStack(spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        flightBatteryStatusDot(status)
                            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
                        Text("VBAT").monoCap(size: 8.5, tracking: 1.5)
                        Text(String(format: "%.1f V", r.volts))
                            .font(.editorialMono(15, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(EditorialTheme.ink)
                        Text("·").foregroundStyle(EditorialTheme.dim)
                        Text("\(r.mah) mAh")
                            .font(.editorialMono(11))
                            .monospacedDigit()
                            .foregroundStyle(EditorialTheme.sub)
                        Spacer(minLength: 8)
                        if let pct = r.pct {
                            Text("\(pct)%")
                                .font(.editorialMono(11))
                                .monospacedDigit()
                                .foregroundStyle(EditorialTheme.sub)
                        }
                    }
                    flightBatteryProgressBar(percent: r.pct)
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                // Bottom gap is owned by `sessionBar.padding(.top, 20)`
                // at the body site so that the gap survives this
                // strip's NO TX hide.
            } else {
                EmptyView()
            }
        }
    }

    /// Two visible states for the flight-battery strip (NO TX hides
    /// the strip entirely, see `flightBatteryStrip`):
    /// - `.live` — a packet decoded within the last
    ///   `flightBatteryStaleAfter` seconds
    /// - `.stale` — packets used to flow but the link has gone quiet.
    ///   Causes: TX powered off, out of range, LUA toggle flipped
    ///   mid-flight
    /// - `.noTx` — never seen a packet since BLE connect (LUA telemetry
    ///   off, or no source bound). Strip is hidden in this state.
    private enum FlightBatteryStatus {
        case live, stale, noTx

        var color: Color {
            switch self {
            case .live: return Color(red: 0.18, green: 0.56, blue: 0.30)  // editorial green
            case .stale: return Color(red: 0.78, green: 0.50, blue: 0.18) // editorial amber
            case .noTx: return EditorialTheme.dim
            }
        }
    }

    @ViewBuilder
    private func flightBatteryStatusDot(_ status: FlightBatteryStatus) -> some View {
        Circle()
            .fill(status.color)
            .frame(width: 7, height: 7)
    }

    private func flightBatteryStatus(at now: Date) -> FlightBatteryStatus {
        guard let last = bluetooth.lastFlightBatteryReceivedAt else { return .noTx }
        return now.timeIntervalSince(last) < Self.flightBatteryStaleAfter ? .live : .stale
    }

    /// 3pt-tall track + ink fill, mirroring the editorial language of
    /// the sessionBar progress without the hairline overlays. Hidden
    /// when remaining-% is unknown (CRSF wire reports −1 in that case)
    /// so the strip never lies about a 0% state. Linear animation on
    /// `pct` so the bar visibly moves with each 1 Hz timeline tick.
    @ViewBuilder
    private func flightBatteryProgressBar(percent: Int?) -> some View {
        if let pct = percent {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(EditorialTheme.hair)
                    Rectangle()
                        .fill(EditorialTheme.ink)
                        .frame(width: max(0, geo.size.width * Double(pct) / 100))
                        .animation(.linear(duration: 0.4), value: pct)
                }
            }
            .frame(height: 3)
        } else {
            EmptyView()
        }
    }

    private struct FlightBatteryReading {
        let volts: Double
        let amps: Double
        let mah: Int
        /// `nil` when remaining is unknown (CRSF wire reports −1 in that
        /// case; iOS surfaces it as nil so the UI can hide the field
        /// instead of showing a misleading "−1%").
        let pct: Int?
    }

    private func flightBatteryReading(at now: Date) -> FlightBatteryReading? {
        guard let voltageDv = bluetooth.flightBatteryVoltageDv,
              let currentDa = bluetooth.flightBatteryCurrentDa,
              let consumedMah = bluetooth.flightBatteryConsumedMah else {
            return nil
        }
        let pct = bluetooth.flightBatteryRemainingPercent
        return FlightBatteryReading(
            volts: Double(voltageDv) / 10.0,
            amps: Double(currentDa) / 10.0,
            mah: consumedMah,
            pct: (pct.map { $0 >= 0 } ?? false) ? pct : nil
        )
    }

    // MARK: - Timer block

    @ViewBuilder
    private var timerBlock: some View {
        if sessionEnded {
            doneBlock
        } else {
            runningBlock
        }
    }

    private var runningBlock: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: -4) {
                Text("Laps").monoCap(size: 9, tracking: 2.0)
                Text(String(format: "%02d", lapTimer.laps.count))
                    .font(.editorialDisplay(64, weight: .light))
                    .monospacedDigit()
                    .tracking(-2)
                    .foregroundStyle(EditorialTheme.ink)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: -4) {
                HStack(spacing: 8) {
                    Text("Current").monoCap(size: 9, tracking: 2.0)
                    Text("Lap \(String(format: "%02d", lapTimer.laps.count + 1))")
                        .monoCap(size: 9, tracking: 2.0)
                }
                BigTime(seconds: currentLapMs,
                        accent: timeUp ? accent : EditorialTheme.ink,
                        size: 64, msSize: 22)
            }
        }
    }

    private var doneBlock: some View {
        let total = lapTimer.laps.reduce(0) { $0 + $1.time }
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: -4) {
                Text("Laps").monoCap(size: 9, tracking: 2.0, color: accent)
                Text(String(format: "%02d", lapTimer.laps.count))
                    .font(.editorialDisplay(64, weight: .light))
                    .monospacedDigit()
                    .tracking(-2)
                    .foregroundStyle(accent)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: -4) {
                Text("Total Time").monoCap(size: 9, tracking: 2.0)
                BigTime(seconds: total, accent: EditorialTheme.ink, size: 64, msSize: 22)
            }
        }
    }

    private var currentLapMs: TimeInterval {
        let completed = lapTimer.laps.reduce(0) { $0 + $1.time }
        return max(0, lapTimer.elapsedTime - completed)
    }

    // MARK: - Summary band

    private var summaryBand: some View {
        let metrics = metricsSnapshot
        return HStack(spacing: 0) {
            SummaryColumn(label: "Target",
                          value: targetSummaryValue,
                          highlight: true, isFirst: true, isLast: false)
            SummaryColumn(label: "Pace",
                          value: metrics?.paceDisplay ?? "—",
                          highlight: false, isFirst: false, isLast: false)
            SummaryColumn(label: "Avg",
                          value: metrics?.avgDisplay ?? (avgTime > 0 ? EditorialFormat.timeShort(avgTime) : "—"),
                          highlight: false, isFirst: false, isLast: false)
            SummaryColumn(label: "Diff",
                          value: metrics?.diffDisplay ?? "—",
                          highlight: metrics?.splitState == .need, isFirst: false, isLast: false)
            SummaryColumn(label: metrics?.splitLabel ?? "Need",
                          value: metrics?.splitValue ?? "—",
                          highlight: metrics?.splitState == .need, isFirst: false, isLast: true)
        }
        .padding(.vertical, 10)
        .padding(.trailing, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(EditorialTheme.ink).frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(EditorialTheme.hair).frame(height: 0.5)
        }
    }

    // MARK: - Lap header + rows + trend column

    private var lapHeader: some View { LapTableHeader() }

    private var lapRowsWithTrend: some View {
        LapTable(laps: lapTimer.laps,
                 bestLapIndex: lapTimer.bestLapIndex,
                 bestTime: bestTime,
                 worstTime: worstTime)
    }

    // MARK: - Ready button

    /// Toggle: tap to push the Ready summary to the goggle, tap again
    /// to wipe it. State lives on `readyShown` so a Settings dismiss
    /// restores Ready iff it was the active frame, and START / RESET
    /// reset the toggle back to off so the next pre-race window starts
    /// with the goggle clean.
    private var readyButton: some View {
        Button {
            if readyShown {
                readyShown = false
                _ = bluetooth.sendOSDControl(command: .clear)
            } else {
                readyShown = true
                sendReadyOSD()
            }
        } label: {
            Text(readyShown ? "HIDE READY" : "SHOW READY")
                .font(.editorialMono(12, weight: .bold))
                .tracking(2.0)
                .foregroundStyle(EditorialTheme.ink)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(
                    EditorialTheme.ink.opacity(readyShown ? 0.5 : 0.2),
                    lineWidth: readyShown ? 1 : 0.5))
        }
    }

    // MARK: - Action dock

    private var actionDock: some View {
        VStack(spacing: 10) {
            if !lapTimer.isRunning && !sessionEnded && lapTimer.laps.isEmpty && bluetooth.isReady {
                readyButton
            }

            ZStack {
                // Chrome matches across STOP/RESET and SHARE so the dock reads as
                // a symmetric trio around the hero button.
                HStack {
                Button(action: secondaryAction) {
                    Text(secondaryLabel)
                        .font(.editorialMono(10, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(secondaryDisabled
                                         ? EditorialTheme.ink.opacity(0.3)
                                         : EditorialTheme.ink.opacity(0.78))
                        .frame(width: 64, height: 64)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(EditorialTheme.ink.opacity(0.14), lineWidth: 0.5))
                        .opacity(secondaryDisabled ? 0.45 : 1)
                }
                .disabled(secondaryDisabled)
                .padding(.leading, 28)

                Spacer()

                if sessionEnded {
                    Button(action: shareAction) {
                        Text("SHARE")
                            .font(.editorialMono(10, weight: .bold))
                            .tracking(1.6)
                            .foregroundStyle(EditorialTheme.ink.opacity(0.78))
                            .frame(width: 64, height: 64)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().stroke(EditorialTheme.ink.opacity(0.14), lineWidth: 0.5))
                    }
                    .accessibilityLabel("Share race result")
                    .padding(.trailing, 28)
                }
            }

            // Primary — giant circle, centered
            Button(action: primaryAction) {
                Text(primaryLabel)
                    .font(.editorialMono(32, weight: .bold))
                    .tracking(2.0)
                    .foregroundStyle(.white)
                    .frame(width: 168, height: 168)
                    .background(
                        Circle().fill(primaryFill)
                    )
                    .shadow(color: primaryShadowColor, radius: 14, x: 0, y: 10)
                    .opacity(primaryDisabled ? 0.55 : 1)
            }
            .disabled(primaryDisabled)
            .scaleEffect(primaryPulse ? 1.0 : 0.985)
            .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                       value: primaryPulse)
            .onAppear { primaryPulse = lapTimer.isRunning }
            .onChange(of: lapTimer.isRunning) { _, running in primaryPulse = running }
        }
        .frame(height: 168)
        .padding(.bottom, 24)
        }
    }

    @State private var primaryPulse = false

    private var primaryLabel: String {
        if sessionEnded { return "DONE" }
        if lapTimer.isRunning { return timeUp ? "FINAL" : "LAP" }
        return "START"
    }

    private var secondaryLabel: String { lapTimer.isRunning ? "STOP" : "RESET" }

    private var primaryDisabled: Bool {
        // iOS state is the source of truth: every action commits locally
        // and best-effort fires at the goggle. BLE state never gates
        // input — `lastError` and the BLE strip surface link issues.
        sessionEnded
    }

    private var secondaryDisabled: Bool {
        if lapTimer.isRunning { return false } // STOP always allowed
        // RESET only when there's something to clear.
        return lapTimer.laps.isEmpty && lapTimer.elapsedTime == 0
    }

    private var primaryFill: Color {
        primaryDisabled ? Color(white: 0.6) : accent
    }

    private var primaryShadowColor: Color {
        primaryDisabled
            ? EditorialTheme.ink.opacity(0.18)
            : accent.opacity(0.34)
    }

    private func primaryAction() {
        if sessionEnded { return }
        if lapTimer.isRunning && timeUp {
            // Set before recordLap() so the .sensoryFeedback closure sees
            // the FINAL classification regardless of when SwiftUI re-evals.
            lastLapWasFinal = true
            // Suppress the per-lap callout on the final lap; the just-
            // recorded lap is folded into the race-end summary phrase
            // (see `announceFinalIfNeeded(lastLap:)`).
            let finalLap = recordLap(announce: false)
            lapTimer.stop()
            announceFinalIfNeeded(lastLap: finalLap)
        } else if lapTimer.isRunning {
            lastLapWasFinal = false
            recordLap()
        } else {
            // Fresh START — wipe stale projection from a previous run so
            // the summary band doesn't briefly show the old pace value.
            metricsSnapshot = nil
            lastLapWasFinal = false
            // Race takes over the goggle: Ready summary is no longer
            // the active frame, so a future Settings dismiss shouldn't
            // restore it.
            readyShown = false
            lapTimer.start()
            raceFlightBatterySamples.removeAll()
            // Audio cue for the start of the race; also warms the audio
            // session so the first lap announcement doesn't pay the
            // setActive(true) round-trip.
            if lapTTSEnabled {
                announcer.announceStart()
            }
        }
    }

    private func secondaryAction() {
        if lapTimer.isRunning {
            lapTimer.stop()
            // STOP ends the session when laps were recorded — flip the
            // view to the result summary instead of leaving the user in
            // a "paused mid-run" state.
            if !lapTimer.laps.isEmpty {
                manuallyEnded = true
                // Stale projection from the in-flight lap would otherwise
                // outlive the run. The achieved count is the truthful pace.
                refreshMetricsSnapshot(paceOverride: lapTimer.laps.count)
                announceFinalIfNeeded()
            }
        } else {
            // iOS state is the source of truth — clear it regardless of
            // whether the goggle ack'd the reset packet. The `lastError`
            // surfaces a failed write so the operator knows the OSD may
            // still show the old table until they reconnect.
            //
            // The 1Hz tick now writes TIME LEFT every second a session
            // is in flight, so a START → STOP → RESET sequence with
            // zero recorded laps still leaves a `TIME LEFT NN` row on
            // the goggle. Trigger the reset whenever the session
            // actually started (`elapsedTime > 0`), not just when laps
            // exist; otherwise the operator returns to a "ready" state
            // on the phone but the goggle keeps showing stale text.
            if !lapTimer.laps.isEmpty || lapTimer.elapsedTime > 0 {
                bluetooth.sendOSDControl(command: .resetLaps)
            }
            // RESET also wipes the goggle overlay so DONE / final-result
            // text from the prior race doesn't sit on the goggle through
            // the next pre-race window. Ready isn't auto-restored — the
            // operator taps SHOW READY again when they want it.
            _ = bluetooth.sendOSDControl(command: .clear)
            // Silence any in-flight announcement before wiping state — a
            // stale "Lap 5, 12.34" trailing into the next session would be
            // disorienting since the visible state was just cleared.
            announcer.cancel()
            lapTimer.reset()
            metricsSnapshot = nil
            manuallyEnded = false
            lastLapWasFinal = false
            readyShown = false
            savedRaceID = nil
            raceFlightBatterySamples.removeAll()
        }
    }

    private func ingestFlightBatteryTelemetry() {
        guard lapTimer.isRunning, !sessionEnded, let started = lapTimer.sessionStartedAt else { return }
        guard let raw = bluetooth.lastFlightBatteryWire else { return }
        // Anchor `tRace` to the BLE notify-arrival moment rather than
        // the SwiftUI observer-tick that called us — the iOS observer
        // tick can run several ms after the notify lands, especially
        // under main-actor pressure. `lastFlightBatteryReceivedAt`
        // moves in lockstep with `lastFlightBatteryWire`, so the pair
        // is always coherent. Falls back to `Date()` for the race-start
        // path where no notify has landed yet.
        //
        // Clamp the `tRace` anchor to `started` so a notify cached from
        // BEFORE the race (BLE connected during pre-race setup, no new
        // notify since) lands the baseline sample at `tRace = 0` instead
        // of a far-negative value that would fail RaceRecord's tRace
        // lower-bound validator and drop the whole record on save
        // (saveRaceIfNeeded only logs the rejection at debug, so the
        // dropped record is otherwise invisible). Pass `receivedAt`
        // separately so `sample.receivedAt` (and the CSV `received_at`
        // export) still reflects the actual BLE-notify arrival time,
        // not the clamped value.
        let receivedAt = bluetooth.lastFlightBatteryReceivedAt ?? Date()
        let now = max(receivedAt, started)
        guard let sample = RaceFlightBatterySample.parseWireV1(raw, raceStartedAt: started, now: now, receivedAt: receivedAt) else { return }
        if let previous = raceFlightBatterySamples.last,
           previous.voltageDv == sample.voltageDv,
           previous.currentDa == sample.currentDa,
           previous.consumedMah == sample.consumedMah,
           previous.remainingPercent == sample.remainingPercent { return }
        raceFlightBatterySamples.append(sample)
    }

    private func saveRaceIfNeeded() {
        guard savedRaceID == nil else { return }
        guard let startedAt = lapTimer.sessionStartedAt else {
            // sessionEnded == true with no startedAt is an invariant
            // violation — log so the next debugging session has a
            // breadcrumb instead of a silently dropped save.
            Self.log.error("saveRaceIfNeeded: sessionEnded but sessionStartedAt is nil")
            return
        }
        let flightSamplesSorted = raceFlightBatterySamples.sortedChronologically()
        guard let record = RaceRecord.snapshot(
            laps: lapTimer.laps,
            startedAt: startedAt,
            sessionLimit: sessionLimit,
            targetLapCount: clampedTargetLapCount,
            accentHue: accentHue,
            flightBatterySamples: flightSamplesSorted
        ) else {
            // Empty / invalid sessions (timeUp without ever lapping) are
            // legitimately skipped, but log so the same skip doesn't
            // look like a mystery later.
            Self.log.debug("saveRaceIfNeeded: skipping — RaceRecord.snapshot rejected the inputs")
            return
        }
        savedRaceID = record.id
        history.add(record)
    }

    private static let log = Logger(subsystem: "sh.saqoo.HDZap", category: "TimerView")

    /// Records the lap locally and fires it at the goggle. iOS state is
    /// the source of truth; a BLE write failure surfaces via `lastError`
    /// but never rolls back the lap — the operator's tap is what counts,
    /// and the goggle catching up (or not) is downstream concern.
    @discardableResult
    private func recordLap(announce: Bool = true) -> Lap? {
        guard let lap = lapTimer.lap() else { return nil }
        refreshMetricsSnapshot()
        sendMetricRows()
        // Refresh TIME LEFT alongside the lap — keeps the top row in
        // sync without waiting up to a second for the next tick.
        sendTimeLeftRow()

        if announce && lapTTSEnabled {
            // `bestLapIndex` is recomputed against `lap` since `lapTimer.lap()`
            // already appended; index N-1 is the lap we just recorded, so an
            // equality check tells us whether it's the new best. On a tie with
            // an earlier lap, `min(by:)` keeps pointing at the earlier index
            // — the tied lap is **not** announced as best, matching the
            // visual highlight in the lap list.
            // Lap 1 is trivially the best (only one), so suppress the
            // "best lap" suffix until we have at least one prior lap to
            // compare against — otherwise every race opens with an
            // unearned victory call.
            let isBest = lapTimer.laps.count > 1
                && lapTimer.bestLapIndex == lapTimer.laps.count - 1
            announcer.announceLap(lap, isBest: isBest)
        }
        return lap
    }

    /// Speaks the race-over summary (lap count + best lap) if TTS is
    /// enabled. Called when the session transitions to ended via either
    /// the final-lap or manual-STOP path. The end-of-race callout is
    /// distinct from the per-lap announcement — it's the one the operator
    /// will care about if they only get to hear one thing per race.
    /// `lastLap` is non-nil only on the FINAL-button path; the manual-STOP
    /// path passes nil because the previous LAP tap already announced the
    /// most-recent lap.
    private func announceFinalIfNeeded(lastLap: Lap? = nil) {
        guard lapTTSEnabled, !lapTimer.laps.isEmpty else { return }
        let totalTime = lapTimer.laps.reduce(0) { $0 + $1.time }
        announcer.announceFinal(lastLap: lastLap,
                                lapCount: lapTimer.laps.count,
                                totalTime: totalTime,
                                bestLapTime: bestTime)
    }

    /// Push the TIME LEFT row to the goggle. Routes via the layout's
    /// buffer slot so a hidden Time row simply skips the BLE write
    /// instead of stamping a blank into the wrong slot. Padded so a
    /// shorter value (e.g. `TIME LEFT 9` after `TIME LEFT 45`) cleanly
    /// overwrites the prior text without a firmware-side clear.
    private func sendTimeLeftRow() {
        let snapshot = osdLayout.snapshot
        guard let slot = snapshot.bufferSlot(forSemanticIndex: 0) else { return }
        let raw = RaceMetrics.timeLeftRaw(remainingSec: remaining)
        bluetooth.sendOSDRow(row: slot, text: snapshot.renderRow(raw, at: 0))
    }

    /// Push the bottom three semantic rows (LAP / AVG / DIFF) when a lap
    /// is recorded, the session limit changes, or the target lap count
    /// changes. Each row is routed to its current buffer slot — hidden
    /// rows are dropped (their slot is owned by another visible row or
    /// a leading blank, both of which sendTimeLeftRow / the layout
    /// flush already handle).
    private func sendMetricRows() {
        guard let metrics = metricsSnapshot else { return }
        let snapshot = osdLayout.snapshot
        let raws = metrics.osdMetricRaws()
        let updates: [(row: Int, text: String)] = raws.enumerated().compactMap { i, raw in
            let semantic = i + 1
            guard let slot = snapshot.bufferSlot(forSemanticIndex: semantic) else { return nil }
            return (row: slot, text: snapshot.renderRow(raw, at: semantic))
        }
        guard !updates.isEmpty else { return }
        bluetooth.sendOSDRows(updates)
    }

    /// Push the pre-race Ready display via the all-visible layout
    /// variant. Per-row hide/show is treated as in-race only — the
    /// pilot still wants to see RACE / target laps / target pace
    /// pre-race even if they hid Lap or Diff for the running display.
    private func sendReadyOSD() {
        let raws = RaceMetrics.readyOSDRaws(
            targetLapCount: clampedTargetLapCount,
            sessionLimit: sessionLimit)
        pushOSDBuffer(osdLayout.snapshot.allVisible, semanticRaws: raws)
    }

    /// Push the post-race results summary to the goggle. Called once
    /// when the session ends so the pilot sees the final tally on the
    /// OSD. Same all-visible rationale as `sendReadyOSD` — no row of
    /// DONE / total / AVG+BEST should be dropped because of an in-race
    /// hide preference.
    private func sendResultOSD() {
        guard !lapTimer.laps.isEmpty else { return }
        let total = lapTimer.laps.reduce(0) { $0 + $1.time }
        let raws = RaceMetrics.resultOSDRaws(
            lapCount: lapTimer.laps.count,
            totalTime: total,
            avgTime: avgTime,
            bestTime: bestTime)
        pushOSDBuffer(osdLayout.snapshot.allVisible, semanticRaws: raws)
    }

    /// Render the 4 semantic raws through `layout` and push the
    /// resulting buffer (always all 4 slots) preceded by the matching
    /// firmware Y offset. The Y-offset prelude matters when the layout
    /// differs from whatever the goggle was last set to (Ready/Result
    /// use `allVisible`, in-race uses the user's partial config) — the
    /// offset and the buffer have to move together so partial-update
    /// callers (sendTimeLeftRow / sendMetricRows) keep landing on the
    /// right grid rows.
    private func pushOSDBuffer(_ layout: OSDLayoutConfig,
                               semanticRaws: [String]) {
        // `urgent: true` → write-with-response so a busy BLE outbound
        // queue can't silently drop the offset right when the goggle
        // is about to render at the wrong base row. State transitions
        // (Ready / Result / race-start / settings-dismiss flush) fire
        // infrequently so the ~30 ms ATT ack cost is acceptable in
        // exchange for atomicity vs. the trailing OSD-text writes.
        _ = bluetooth.sendOSDLayout(yOffset: layout.firmwareYOffset, urgent: true)
        let buffer = layout.renderBuffer(semanticRaws: semanticRaws)
        let updates = (0..<OSDLayoutConfig.rowCount).map {
            (row: $0, text: buffer[$0])
        }
        bluetooth.sendOSDRows(updates)
    }

    /// Repaint the goggle with whatever the current race state would
    /// naturally show. Mirrors the push paths that would have fired had
    /// the operator stayed on this screen instead of opening Settings:
    /// Result for an ended race, Running (TIME LEFT + lap metrics) for
    /// an in-flight race with at least one lap, Ready for a fresh /
    /// pre-start state *only* if the operator had explicitly tapped
    /// SHOW READY before opening Settings. Otherwise the goggle just
    /// gets cleared so a stale dummy preview from the layout editor
    /// doesn't linger and the pilot sees what they had before.
    /// No-op if BLE isn't ready (caller already checks in the dismiss
    /// path, but defending here keeps the helper safe).
    private func flushCurrentRaceFrame() {
        guard bluetooth.isReady else { return }
        if sessionEnded, !lapTimer.laps.isEmpty {
            sendResultOSD()
            return
        }
        if lapTimer.isRunning, let metrics = metricsSnapshot {
            let raws: [String] = [RaceMetrics.timeLeftRaw(remainingSec: remaining)]
                + metrics.osdMetricRaws()
            pushOSDBuffer(osdLayout.snapshot, semanticRaws: raws)
            return
        }
        if lapTimer.isRunning {
            // Running but pre-first-lap: keep showing TIME LEFT on top
            // and clear the lower rows so stale Ready or dummy preview
            // text doesn't linger.
            pushOSDBuffer(osdLayout.snapshot, semanticRaws: [
                RaceMetrics.timeLeftRaw(remainingSec: remaining), "", "", "",
            ])
            return
        }
        if readyShown {
            sendReadyOSD()
            return
        }
        // Idle pre-race + Ready not requested: just wipe the goggle so
        // any dummy preview rows from the layout editor disappear. The
        // operator tapping SHOW READY (or starting the race) is what
        // brings real content back.
        _ = bluetooth.sendOSDControl(command: .clear)
    }

    private func clampTargetLapCountSetting() {
        let clamped = RaceMetrics.clampedTargetLapCount(targetLapCount)
        if targetLapCount != clamped {
            targetLapCount = clamped
        }
    }

    private func handleTargetLapCountChange() {
        let clamped = RaceMetrics.clampedTargetLapCount(targetLapCount)
        if targetLapCount != clamped {
            targetLapCount = clamped
            return
        }
        refreshMetricsSnapshot()
        sendMetricRows()
    }

    @discardableResult
    private func refreshMetricsSnapshot(paceOverride: Int? = nil) -> RaceMetrics? {
        let metrics = RaceMetrics(laps: lapTimer.laps,
                                  targetLapCount: clampedTargetLapCount,
                                  sessionLimit: sessionLimit,
                                  paceOverride: paceOverride)
        metricsSnapshot = metrics
        return metrics
    }

    // MARK: - Share

    private func shareAction() {
        // Drop the previous share file before allocating a new one so a fast
        // SHARE → cancel → SHARE loop doesn't strand temp PNGs even though
        // `cleanupShareTempFile` will also fire on dismiss.
        cleanupShareTempFile()
        do {
            let url = try makeShareImage()
            lastShareURL = url
            shareItem = ShareItem(url: url)
        } catch {
            shareError = ShareImageError.userMessage(for: error)
        }
    }

    private func cleanupShareTempFile() {
        if let url = lastShareURL {
            ShareImageError.cleanupTempFile(at: url, log: Self.log)
            lastShareURL = nil
        }
    }

    @MainActor
    private func makeShareImage() throws -> URL {
        try RaceShareCard.renderImage(
            laps: lapTimer.laps,
            bestLapIndex: lapTimer.bestLapIndex,
            metrics: metricsSnapshot,
            accentHue: accentHue,
            targetLapCount: clampedTargetLapCount,
            sessionLimit: sessionLimit,
            generatedAt: Date(),
            flightBatterySamples: raceFlightBatterySamples.sortedChronologically()
        )
    }
}

// MARK: - Share errors

enum ShareImageError: Error {
    case rendererProducedNoImage
    case pngEncodeFailed

    var userMessage: String {
        switch self {
        case .rendererProducedNoImage:
            return "Render produced no image. Try restarting the app."
        case .pngEncodeFailed:
            return "PNG encode failed. Try again."
        }
    }

    /// Single source of truth for "render error → user-facing copy" so
    /// every share call site (live race + history detail) maps the same
    /// failure to the same alert text.
    static func userMessage(for error: Error) -> String {
        if let imageError = error as? ShareImageError {
            return imageError.userMessage
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain
            && nsError.code == NSFileWriteOutOfSpaceError {
            return "Out of storage. Free space and try again."
        }
        return "Couldn't save race image: \(error.localizedDescription)"
    }

    /// Best-effort temp-file removal. `NSFileNoSuchFileError` is silent
    /// (the OS reaped it already); anything else is logged so a leak
    /// doesn't pile up undetected. Caller still owns the `URL` lifetime.
    static func cleanupTempFile(at url: URL, log: Logger) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as NSError where error.code == NSFileNoSuchFileError {
            // already reaped — fine
        } catch {
            log.debug("Couldn't remove share temp \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}

// MARK: - Share helpers

/// Wraps `URL` so `.sheet(item:)` has an `Identifiable` payload — `URL`
/// isn't `Identifiable` itself, and a fresh `id` per instance forces SwiftUI
/// to remount the share sheet so a stale render is never reused.
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Used instead of `ShareLink` because `ShareLink` needs the item at
/// construction time, but the PNG is rendered lazily on tap.
///
/// The popover anchor is set unconditionally — `TARGETED_DEVICE_FAMILY = "1,2"`
/// means iPad builds reach this code, and on iPad UIKit asserts when a popover
/// presentation has no `sourceView`. The `.sheet(item:)` host typically forces
/// a sheet style that ignores the popover settings, but setting them is
/// cheap insurance against the assertion.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = vc.popoverPresentationController {
            popover.sourceView = vc.view
            popover.sourceRect = CGRect(x: vc.view.bounds.midX,
                                        y: vc.view.bounds.midY,
                                        width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - StatusDot

private struct StatusDot: View {
    let active: Bool
    let color: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.6)) { ctx in
            let beat = Int(ctx.date.timeIntervalSinceReferenceDate / 0.6) % 2
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
                .opacity(active && beat == 0 ? 0.35 : 1)
        }
    }
}

// MARK: - BigTime

struct BigTime: View {
    let seconds: TimeInterval
    let accent: Color
    var size: CGFloat = 64
    var msSize: CGFloat = 22

    var body: some View {
        let total = max(0, Int((seconds * 1000).rounded(.down)))
        let m = total / 60_000
        let s = (total % 60_000) / 1000
        let f = total % 1000

        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(String(format: "%02d", m))
                .font(.editorialDisplay(size, weight: .light))
                .monospacedDigit()
                .tracking(-2)
                .foregroundStyle(accent)
            Text(":")
                .font(.editorialDisplay(size, weight: .light))
                .foregroundStyle(EditorialTheme.ink.opacity(0.25))
                .padding(.horizontal, 1)
                .offset(y: -size * 0.10)
            Text(String(format: "%02d", s))
                .font(.editorialDisplay(size, weight: .light))
                .monospacedDigit()
                .tracking(-2)
                .foregroundStyle(accent)
            Text(".\(String(format: "%03d", f))")
                .font(.editorialDisplay(msSize, weight: .light))
                .monospacedDigit()
                .foregroundStyle(EditorialTheme.ink.opacity(0.45))
                .padding(.leading, 6)
        }
        .lineLimit(1)
        // 0.9 (not the prior 0.5) is deliberate: SwiftUI was firing the
        // scale on this firstTextBaseline HStack with mixed font sizes
        // (64pt + 22pt) even when the proposed width comfortably exceeded
        // the natural width — verified on device with a colored debug
        // background where BigTime rendered at ~50 % of nominal in the
        // share card's doneBlock. Keeping a token safety net at 0.9 means
        // the fallback only kicks in for real >10 % overflow (none in the
        // current `[60, 180]`s session-limit envelope) instead of phantom
        // shrinking the hero digits below the LAPS hero number's size.
        .minimumScaleFactor(0.9)
    }
}

// MARK: - SummaryColumn

struct SummaryColumn: View {
    let label: String
    let value: String
    let highlight: Bool
    let isFirst: Bool
    let isLast: Bool
    @Environment(\.accentHue) private var accentHue: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).monoCap(size: 8.5, tracking: 1.2)
            Text(value)
                .font(.editorialMono(14, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(highlight ? EditorialTheme.accent(hue: accentHue) : EditorialTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, isFirst ? 0 : 8)
        .padding(.trailing, isLast ? 0 : 8)
        .overlay(alignment: .trailing) {
            if !isLast {
                Rectangle().fill(EditorialTheme.hair).frame(width: 0.5)
            }
        }
    }
}

// MARK: - EditorialLapRow

struct EditorialLapRow: View {
    let lap: Lap
    let isBest: Bool
    let delta: TimeInterval
    var height: CGFloat = LapTableMetrics.rowHeight
    @Environment(\.accentHue) private var accentHue: Double
    private var accent: Color { EditorialTheme.accent(hue: accentHue) }

    var body: some View {
        HStack(spacing: LapTableMetrics.headerSpacing) {
            Text(String(format: "%02d", lap.id))
                .font(.editorialMono(13))
                .monospacedDigit()
                .foregroundStyle(EditorialTheme.sub)
                .frame(width: LapTableMetrics.numberColumnWidth, alignment: .leading)

            HStack(spacing: 6) {
                Text(EditorialFormat.time(lap.time, msDigits: 2))
                    .font(.editorialMono(18, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(isBest ? accent : EditorialTheme.ink)
                if isBest {
                    Text("★")
                        .font(.editorialMono(11))
                        .tracking(1.4)
                        .foregroundStyle(accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(isBest ? "·BEST" : EditorialFormat.delta(delta))
                .font(.editorialMono(13))
                .monospacedDigit()
                .foregroundStyle(isBest ? accent : EditorialTheme.sub)
                .frame(width: LapTableMetrics.deltaColumnWidth, alignment: .trailing)
        }
        .frame(height: height)
        .overlay(alignment: .bottom) {
            Rectangle().fill(EditorialTheme.hair).frame(height: 0.5)
        }
    }
}

// MARK: - LapTrendChartVertical

/// Vertical trend chart aligned to the right of the lap-row table. One
/// dot per lap, positioned at the same y as its row — see `order` for
/// row sequencing. X scales lap time from 0 (left = fast) to
/// slowest * 1.05 (right = slow).
struct LapTrendChartVertical: View {
    let laps: [Lap]
    let bestIdx: Int?
    let worstT: TimeInterval
    let rowHeight: CGFloat
    /// Row direction. Defaults to `.newestFirst` (live timer); pass
    /// `.chronological` from the post-race history detail / shared PNG so
    /// the trend dots stay aligned with whatever ordering the lap-row
    /// table picks. See `LapOrder` for the rationale behind each value.
    var order: LapOrder = .newestFirst
    @Environment(\.accentHue) private var accentHue: Double

    var body: some View {
        let totalH = CGFloat(laps.count) * rowHeight
        let span = max(0.001, worstT * 1.05)
        let ordered = order == .chronological
            ? Array(laps.enumerated())
            : Array(laps.enumerated().reversed())

        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                // Vertical axis at left edge — origin reference.
                Rectangle()
                    .fill(EditorialTheme.hair)
                    .frame(width: 0.5)

                // Connecting line through dots
                Path { path in
                    for (display, (_, lap)) in ordered.enumerated() {
                        let x = max(2, CGFloat(lap.time / span) * w)
                        let y = (CGFloat(display) + 0.5) * rowHeight
                        if display == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(EditorialTheme.ink.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1, lineJoin: .round))

                ForEach(Array(ordered.enumerated()), id: \.element.1.id) { display, item in
                    let (origIdx, lap) = item
                    let isBest = origIdx == bestIdx
                    let x = max(2, CGFloat(lap.time / span) * w)
                    let y = (CGFloat(display) + 0.5) * rowHeight
                    Circle()
                        .fill(isBest ? EditorialTheme.accent(hue: accentHue) : EditorialTheme.ink)
                        .frame(width: isBest ? 7 : 4.5, height: isBest ? 7 : 4.5)
                        .overlay(
                            Circle().stroke(EditorialTheme.paper, lineWidth: isBest ? 1.5 : 1)
                        )
                        .position(x: x, y: y)
                }
            }
        }
        .frame(height: max(rowHeight, totalH))
    }
}

// MARK: - LapTable (shared by TimerView and RaceShareCard)

/// Single source of truth for the lap-table geometry. The on-screen post-race
/// view (`TimerView`) and the offscreen share-image card (`RaceShareCard`)
/// must agree pixel-for-pixel so the shared PNG reads as the screen the
/// operator was watching — promoting these constants here removes the silent
/// rot path where one side's row height drifts from the other.
enum LapTableMetrics {
    static let rowHeight: CGFloat = 42
    static let trendColumnWidth: CGFloat = 110
    static let numberColumnWidth: CGFloat = 26
    static let deltaColumnWidth: CGFloat = 72
    static let headerSpacing: CGFloat = 10
    static let bodySpacing: CGFloat = 8
    static let emptyStatePadding: CGFloat = 28
    static let headerFontSize: CGFloat = 10
    static let headerTracking: CGFloat = 1.6
}

struct LapTableHeader: View {
    var body: some View {
        HStack(spacing: LapTableMetrics.headerSpacing) {
            Text("#")
                .monoCap(size: LapTableMetrics.headerFontSize, tracking: LapTableMetrics.headerTracking)
                .frame(width: LapTableMetrics.numberColumnWidth, alignment: .leading)
            Text("Split")
                .monoCap(size: LapTableMetrics.headerFontSize, tracking: LapTableMetrics.headerTracking)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Δ Best")
                .monoCap(size: LapTableMetrics.headerFontSize, tracking: LapTableMetrics.headerTracking)
                .frame(width: LapTableMetrics.deltaColumnWidth, alignment: .trailing)
            Text("Trend")
                .monoCap(size: LapTableMetrics.headerFontSize, tracking: LapTableMetrics.headerTracking)
                .frame(width: LapTableMetrics.trendColumnWidth, alignment: .center)
        }
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(EditorialTheme.hair).frame(height: 0.5)
        }
    }
}

/// Direction the lap rows (and the matching trend dots) read in. The two
/// modes are load-bearing UX decisions, not display preference: live
/// timing wants the most recent split next to the running clock so the
/// driver's eye doesn't have to track down a moving list; the post-race
/// history detail and the shared PNG are read as a race timeline so lap
/// 1 belongs at the top.
enum LapOrder {
    /// Live-timer default: newest lap at the top, oldest at the bottom.
    case newestFirst
    /// Post-race / share / history: lap 1 at the top, latest at the bottom.
    case chronological
}

struct LapTable: View {
    let laps: [Lap]
    let bestLapIndex: Int?
    let bestTime: TimeInterval?
    let worstTime: TimeInterval?
    /// Threaded into `LapTrendChartVertical` so the trend dots stay
    /// row-aligned in either order.
    var order: LapOrder = .newestFirst

    var body: some View {
        if laps.isEmpty {
            Text("No laps")
                .monoCap(size: 11, tracking: 1.2, color: EditorialTheme.dim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, LapTableMetrics.emptyStatePadding)
        } else {
            HStack(alignment: .top, spacing: LapTableMetrics.bodySpacing) {
                VStack(spacing: 0) {
                    let ordered = order == .chronological
                        ? Array(laps.enumerated())
                        : Array(laps.enumerated().reversed())
                    ForEach(ordered, id: \.element.id) { realIdx, lap in
                        let isBest = realIdx == bestLapIndex
                        let delta = (bestTime ?? 0) > 0 ? lap.time - (bestTime ?? 0) : 0
                        EditorialLapRow(lap: lap, isBest: isBest, delta: delta,
                                        height: LapTableMetrics.rowHeight)
                    }
                }
                .frame(maxWidth: .infinity)

                LapTrendChartVertical(
                    laps: laps,
                    bestIdx: bestLapIndex,
                    worstT: worstTime ?? 0,
                    rowHeight: LapTableMetrics.rowHeight,
                    order: order
                )
                .frame(width: LapTableMetrics.trendColumnWidth)
            }
        }
    }
}
