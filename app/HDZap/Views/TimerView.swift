import SwiftUI
import UIKit

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
    @AppStorage("targetLapCount") private var targetLapCount = RaceMetrics.defaultTargetLapCount
    @AppStorage("raceSessionLimit") private var raceSessionLimit: Int = 90
    @AppStorage(LapAnnouncerDefaults.enabledKey) private var lapTTSEnabled = false
    @Environment(\.accentHue) private var accentHue: Double
    private var accent: Color { EditorialTheme.accent(hue: accentHue) }
    private var sessionLimit: TimeInterval { TimeInterval(raceSessionLimit) }

    @State private var showSettings = false
    /// Captured once at the moment a lap is recorded. Kept stable so the
    /// displayed projection/diff doesn't tick every frame as the in-flight
    /// lap consumes the remaining window. Cleared on START and RESET.
    @State private var metricsSnapshot: RaceMetrics?
    /// Set when the user taps STOP with at least one recorded lap so the
    /// view flips to the result/done summary. STOP with no laps just pauses
    /// the timer — no point showing an empty results screen. Cleared by RESET.
    @State private var manuallyEnded = false
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
                } else if !bluetooth.isReady {
                    // Surface link state passively — actions always run
                    // against iOS state, but the operator should know the
                    // goggle won't update until BLE is back.
                    bleStrip
                }

                ScrollView {
                    VStack(spacing: 0) {
                        sessionBar
                            .padding(.horizontal, 24)
                            .padding(.top, 6)

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
                    .padding(.bottom, 220) // ActionDock clearance
                }
                .scrollIndicators(.hidden)
            }

            actionDock
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
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
            if let metrics = refreshMetricsSnapshot() {
                bluetooth.sendOSDText(lines: metrics.osdLines)
            }
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
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    /// Compose a short status line about the error backlog. Keeps the two
    /// counters separate so e.g. `suppressed > 0, queued == 0` doesn't render
    /// as a misleading `"+0 more queued"`.
    private func errorSummaryLine(queued: Int, suppressed: Int) -> String {
        var parts: [String] = []
        if queued > 0 { parts.append("+\(queued) more queued") }
        if suppressed > 0 { parts.append("+\(suppressed) suppressed") }
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
            HStack {
                HStack(spacing: 6) {
                    Text("Elapsed").monoCap(size: 8.5, tracking: 1.5)
                    Text(EditorialFormat.time(lapTimer.elapsedTime, msDigits: 2))
                        .font(.editorialMono(10))
                        .monospacedDigit()
                        .foregroundStyle(EditorialTheme.ink)
                }
                Spacer()
                HStack(spacing: 6) {
                    Text("Remain").monoCap(size: 8.5, tracking: 1.5)
                    Text(EditorialFormat.time(remaining, msDigits: 2))
                        .font(.editorialMono(10))
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

    private static let lapRowHeight: CGFloat = 42
    private static let trendColumnWidth: CGFloat = 110

    private var lapHeader: some View {
        HStack(spacing: 10) {
            Text("#").monoCap(size: 10, tracking: 1.6).frame(width: 26, alignment: .leading)
            Text("Split").monoCap(size: 10, tracking: 1.6).frame(maxWidth: .infinity, alignment: .leading)
            Text("Δ Best").monoCap(size: 10, tracking: 1.6).frame(width: 72, alignment: .trailing)
            Text("Trend").monoCap(size: 10, tracking: 1.6)
                .frame(width: Self.trendColumnWidth, alignment: .center)
        }
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(EditorialTheme.hair).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var lapRowsWithTrend: some View {
        if lapTimer.laps.isEmpty {
            Text("No laps")
                .monoCap(size: 11, tracking: 1.2, color: EditorialTheme.dim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        } else {
            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: 0) {
                    ForEach(Array(lapTimer.laps.enumerated().reversed()), id: \.element.id) { realIdx, lap in
                        let isBest = realIdx == lapTimer.bestLapIndex
                        let delta = (bestTime ?? 0) > 0 ? lap.time - (bestTime ?? 0) : 0
                        EditorialLapRow(lap: lap, isBest: isBest, delta: delta,
                                        height: Self.lapRowHeight)
                    }
                }
                .frame(maxWidth: .infinity)

                LapTrendChartVertical(
                    laps: lapTimer.laps,
                    bestIdx: lapTimer.bestLapIndex,
                    worstT: worstTime ?? 0,
                    rowHeight: Self.lapRowHeight
                )
                .frame(width: Self.trendColumnWidth)
            }
        }
    }

    // MARK: - Action dock

    private var actionDock: some View {
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
            recordLap()
            lapTimer.stop()
        } else if lapTimer.isRunning {
            recordLap()
        } else {
            // Fresh START — wipe stale projection from a previous run so
            // the summary band doesn't briefly show the old pace value.
            metricsSnapshot = nil
            lapTimer.start()
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
            }
        } else {
            // iOS state is the source of truth — clear it regardless of
            // whether the goggle ack'd the reset packet. The `lastError`
            // surfaces a failed write so the operator knows the OSD may
            // still show the old table until they reconnect.
            if !lapTimer.laps.isEmpty {
                bluetooth.sendOSDControl(command: .resetLaps)
            }
            // Silence any in-flight announcement before wiping state — a
            // stale "Lap 5, 12.34" trailing into the next session would be
            // disorienting since the visible state was just cleared.
            announcer.cancel()
            lapTimer.reset()
            metricsSnapshot = nil
            manuallyEnded = false
        }
    }

    /// Records the lap locally and fires it at the goggle. iOS state is
    /// the source of truth; a BLE write failure surfaces via `lastError`
    /// but never rolls back the lap — the operator's tap is what counts,
    /// and the goggle catching up (or not) is downstream concern.
    private func recordLap() {
        guard let lap = lapTimer.lap() else { return }

        if let metrics = refreshMetricsSnapshot() {
            bluetooth.sendOSDText(lines: metrics.osdLines)
        }

        if lapTTSEnabled {
            // bestLapIndex is recomputed against `lap` since lapTimer.lap()
            // already appended; index N-1 is the lap we just recorded, so
            // an equality check tells us whether it's the new best.
            let isBest = lapTimer.bestLapIndex == lapTimer.laps.count - 1
            announcer.announceLap(lap, isBest: isBest)
        }
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
        if let metrics = refreshMetricsSnapshot() {
            bluetooth.sendOSDText(lines: metrics.osdLines)
        }
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
        } catch let error as ShareImageError {
            shareError = error.userMessage
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
                                         && error.code == NSFileWriteOutOfSpaceError {
            shareError = "Out of storage. Free space and try again."
        } catch {
            shareError = "Couldn't save race image: \(error.localizedDescription)"
        }
    }

    private func cleanupShareTempFile() {
        if let url = lastShareURL {
            try? FileManager.default.removeItem(at: url)
            lastShareURL = nil
        }
    }

    /// Returns the URL of a freshly written PNG. Throws `ShareImageError`
    /// when `ImageRenderer` produces no image or when PNG encoding fails;
    /// rethrows the underlying error from `data.write` so out-of-space and
    /// permission failures reach `shareAction()` for distinct user messages.
    @MainActor
    private func makeShareImage() throws -> URL {
        let card = RaceShareCard(
            laps: lapTimer.laps,
            bestLapIndex: lapTimer.bestLapIndex,
            metrics: metricsSnapshot,
            accentHue: accentHue,
            targetLapCount: clampedTargetLapCount,
            sessionLimit: sessionLimit,
            generatedAt: Date()
        )
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        guard let uiImage = renderer.uiImage else {
            throw ShareImageError.rendererProducedNoImage
        }
        guard let data = uiImage.pngData() else {
            throw ShareImageError.pngEncodeFailed
        }
        // Per-share UUID suffix prevents collisions when the user taps SHARE
        // twice within the same second (timestamp resolution is seconds).
        let stamp = Self.fileTimestampFormatter.string(from: Date())
        let suffix = UUID().uuidString.prefix(6)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hdzap-race-\(stamp)-\(suffix).png")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static let fileTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        // Filename-safe; sortable. Avoids `:` which some share targets reject.
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
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
        .minimumScaleFactor(0.5)
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
    var height: CGFloat = 42
    @Environment(\.accentHue) private var accentHue: Double
    private var accent: Color { EditorialTheme.accent(hue: accentHue) }

    var body: some View {
        HStack(spacing: 10) {
            Text(String(format: "%02d", lap.id))
                .font(.editorialMono(13))
                .monospacedDigit()
                .foregroundStyle(EditorialTheme.sub)
                .frame(width: 26, alignment: .leading)

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
                .frame(width: 72, alignment: .trailing)
        }
        .frame(height: height)
        .overlay(alignment: .bottom) {
            Rectangle().fill(EditorialTheme.hair).frame(height: 0.5)
        }
    }
}

// MARK: - LapTrendChartVertical

/// Vertical trend chart aligned to the right of the lap-row table.
/// One dot per lap, positioned at the same y as its row (newest at top).
/// X scales lap time from 0 (left = fast) to slowest * 1.05 (right = slow).
struct LapTrendChartVertical: View {
    let laps: [Lap]
    let bestIdx: Int?
    let worstT: TimeInterval
    let rowHeight: CGFloat
    @Environment(\.accentHue) private var accentHue: Double

    var body: some View {
        let totalH = CGFloat(laps.count) * rowHeight
        let span = max(0.001, worstT * 1.05)
        // Newest first to align with the lap rows order.
        let ordered = Array(laps.enumerated().reversed())

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
