import SwiftUI

/// Editorial Console — quiet typography, hairline rules, inline sparkbars.
/// Modeled on the iOS Lap Timer handoff prototype (V2 Editorial).
///
/// 90-second time-attack window: count as many laps as possible before the
/// session bar runs out. The lap in flight when 90s passes is the FINAL lap;
/// pressing the primary button records it and ends the session.
struct TimerView: View {
    @Environment(LapTimer.self) private var lapTimer
    @Environment(BluetoothManager.self) private var bluetooth

    @State private var showConnection = false
    /// Pace projection is captured at the instant a lap is recorded — it
    /// shouldn't drift downward live as the in-flight lap eats into the
    /// projection window. Cleared on reset/start.
    @State private var paceSnapshot: Int?
    /// Set when the user taps STOP with at least one recorded lap so the
    /// view flips to the result/done summary. Cleared by RESET.
    @State private var manuallyEnded = false

    private var timeUp: Bool { lapTimer.elapsedTime >= EditorialTheme.sessionLimit }
    private var sessionEnded: Bool {
        manuallyEnded || (!lapTimer.isRunning && timeUp)
    }
    private var remaining: TimeInterval { max(0, EditorialTheme.sessionLimit - lapTimer.elapsedTime) }
    private var progress: Double { min(1, lapTimer.elapsedTime / EditorialTheme.sessionLimit) }
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
    private var pace: Int? { paceSnapshot }

    var body: some View {
        ZStack(alignment: .bottom) {
            EditorialTheme.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                masthead

                if let err = bluetooth.lastError {
                    errorStrip(err)
                }
                if !bluetooth.isConnected {
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
        .sheet(isPresented: $showConnection) {
            ConnectionView()
        }
    }

    // MARK: - Masthead

    private var masthead: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Time Attack · 90s")
                .monoCap(size: 9.5, tracking: 2.0)

            Text("•")
                .font(.system(size: 9))
                .foregroundStyle(EditorialTheme.dim)

            HStack(spacing: 6) {
                StatusDot(active: lapTimer.isRunning && !sessionEnded,
                          color: timeUp ? EditorialTheme.accent : (lapTimer.isRunning ? EditorialTheme.accent : EditorialTheme.dim))
                Text(stateLabel)
                    .monoCap(size: 9.5, tracking: 1.5,
                             color: timeUp ? EditorialTheme.accent : EditorialTheme.sub)
            }

            Spacer()

            Button {
                showConnection = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(EditorialTheme.ink)
                    .frame(width: 30, height: 30)
                    .background(EditorialTheme.ink.opacity(0.06), in: Circle())
            }
            .accessibilityLabel("Connection settings")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    private var stateLabel: String {
        if sessionEnded { return "DONE" }
        if timeUp && lapTimer.isRunning { return "FINAL LAP" }
        return lapTimer.isRunning ? "LIVE" : "PAUSED"
    }

    private func errorStrip(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(EditorialTheme.accent)
            Text(message)
                .font(.editorialMono(10, weight: .regular))
                .foregroundStyle(EditorialTheme.ink)
                .lineLimit(2)
            Spacer()
            Button("DISMISS") { bluetooth.clearError() }
                .monoCap(size: 9, tracking: 1.4, color: EditorialTheme.sub)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(EditorialTheme.accent.opacity(0.08))
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
            Button("OPEN") { showConnection = true }
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
                        .foregroundStyle(timeUp ? EditorialTheme.accent : EditorialTheme.ink)
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

                // Tick marks every 10s
                GeometryReader { geo in
                    ForEach(1..<9, id: \.self) { i in
                        Rectangle()
                            .fill(EditorialTheme.hairStrong)
                            .frame(width: 1)
                            .offset(x: geo.size.width * Double(i) / 9)
                    }
                }

                // Fill
                GeometryReader { geo in
                    Rectangle()
                        .fill(EditorialTheme.accent)
                        .frame(width: max(0, geo.size.width * progress))
                        .animation(.linear(duration: 0.08), value: progress)

                    // Leading-edge cursor
                    TimelineView(.periodic(from: .now, by: 0.45)) { ctx in
                        let pulsing = lapTimer.isRunning && progress < 1
                        let beat = Int(ctx.date.timeIntervalSinceReferenceDate / 0.45) % 2
                        Rectangle()
                            .fill(progress >= 1 ? EditorialTheme.accent : EditorialTheme.ink)
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
                Text("30").monoCap(size: 8.5, tracking: 1.5)
                Spacer()
                Text("60").monoCap(size: 8.5, tracking: 1.5)
                Spacer()
                Text("90").monoCap(size: 8.5, tracking: 1.5)
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
                BigTime(ms: currentLapMs,
                        accent: timeUp ? EditorialTheme.accent : EditorialTheme.ink,
                        size: 64, msSize: 22)
            }
        }
    }

    private var doneBlock: some View {
        let total = lapTimer.laps.reduce(0) { $0 + $1.time }
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: -4) {
                Text("Laps").monoCap(size: 9, tracking: 2.0, color: EditorialTheme.accent)
                Text(String(format: "%02d", lapTimer.laps.count))
                    .font(.editorialDisplay(64, weight: .light))
                    .monospacedDigit()
                    .tracking(-2)
                    .foregroundStyle(EditorialTheme.accent)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: -4) {
                Text("Total Time").monoCap(size: 9, tracking: 2.0)
                BigTime(ms: total, accent: EditorialTheme.ink, size: 64, msSize: 22)
            }
        }
    }

    private var currentLapMs: TimeInterval {
        let completed = lapTimer.laps.reduce(0) { $0 + $1.time }
        return max(0, lapTimer.elapsedTime - completed)
    }

    // MARK: - Summary band

    private var summaryBand: some View {
        HStack(spacing: 0) {
            SummaryColumn(label: "Pace",
                          value: pace.map { "→\(String(format: "%02d", $0))" } ?? "—",
                          highlight: true, isFirst: true, isLast: false)
            SummaryColumn(label: "Best",
                          value: bestTime.map { EditorialFormat.timeShort($0) } ?? "—",
                          highlight: false, isFirst: false, isLast: false)
            SummaryColumn(label: "Avg",
                          value: avgTime > 0 ? EditorialFormat.timeShort(avgTime) : "—",
                          highlight: false, isFirst: false, isLast: true)
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

    // MARK: - Histogram

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
            // Secondary — STOP / RESET, left of hero
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
        sessionEnded
    }

    private var secondaryDisabled: Bool {
        if lapTimer.isRunning { return false } // STOP always allowed
        return lapTimer.laps.isEmpty && lapTimer.elapsedTime == 0
    }

    private var primaryFill: Color {
        primaryDisabled ? Color(white: 0.6) : EditorialTheme.accent
    }

    private var primaryShadowColor: Color {
        primaryDisabled
            ? EditorialTheme.ink.opacity(0.18)
            : EditorialTheme.accent.opacity(0.34)
    }

    private func primaryAction() {
        if sessionEnded { return }
        if lapTimer.isRunning && timeUp {
            recordLap()
            lapTimer.stop()
        } else if lapTimer.isRunning {
            recordLap()
        } else {
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
            }
        } else {
            bluetooth.sendOSDControl(command: .resetLaps)
            lapTimer.reset()
            paceSnapshot = nil
            manuallyEnded = false
        }
    }

    private func recordLap() {
        guard let lap = lapTimer.lap() else { return }
        let rawMs = Int64((lap.time * 1000).rounded())
        let timeMs = UInt32(clamping: rawMs)
        let lapByte = UInt8(truncatingIfNeeded: lap.id)
        bluetooth.sendLapTime(lapNum: lapByte, timeMs: timeMs)
        // Snapshot pace at the moment of the lap. Counts completed laps +
        // the in-flight lap that just started + however many more fit in
        // the remaining session at the new average.
        let avg = lapTimer.laps.reduce(0) { $0 + $1.time } / Double(lapTimer.laps.count)
        if avg > 0 {
            paceSnapshot = lapTimer.laps.count + 1 + Int(max(0, remaining) / avg)
        }
    }
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

private struct BigTime: View {
    let ms: TimeInterval
    let accent: Color
    var size: CGFloat = 64
    var msSize: CGFloat = 22

    var body: some View {
        let total = max(0, Int((ms * 1000).rounded(.down)))
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

private struct SummaryColumn: View {
    let label: String
    let value: String
    let highlight: Bool
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).monoCap(size: 9, tracking: 1.6)
            Text(value)
                .font(.editorialMono(18, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(highlight ? EditorialTheme.accent : EditorialTheme.ink)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, isFirst ? 0 : 12)
        .padding(.trailing, isLast ? 0 : 12)
        .overlay(alignment: .trailing) {
            if !isLast {
                Rectangle().fill(EditorialTheme.hair).frame(width: 0.5)
            }
        }
    }
}

// MARK: - EditorialLapRow

private struct EditorialLapRow: View {
    let lap: Lap
    let isBest: Bool
    let delta: TimeInterval
    var height: CGFloat = 42

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
                    .foregroundStyle(isBest ? EditorialTheme.accent : EditorialTheme.ink)
                if isBest {
                    Text("★")
                        .font(.editorialMono(11))
                        .tracking(1.4)
                        .foregroundStyle(EditorialTheme.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(isBest ? "·BEST" : EditorialFormat.delta(delta))
                .font(.editorialMono(13))
                .monospacedDigit()
                .foregroundStyle(isBest ? EditorialTheme.accent : EditorialTheme.sub)
                .frame(width: 72, alignment: .trailing)
        }
        .frame(height: height)
        .overlay(alignment: .bottom) {
            Rectangle().fill(EditorialTheme.hair).frame(height: 0.5)
        }
    }
}

// MARK: - EditorialHistogram

/// Vertical trend chart aligned to the right of the lap-row table.
/// One dot per lap, positioned at the same y as its row (newest at top).
/// X scales lap time from 0 (left = fast) to slowest * 1.05 (right = slow).
private struct LapTrendChartVertical: View {
    let laps: [Lap]
    let bestIdx: Int?
    let worstT: TimeInterval
    let rowHeight: CGFloat

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
                        .fill(isBest ? EditorialTheme.accent : EditorialTheme.ink)
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

private struct LapTrendChart: View {
    let laps: [Lap]
    let bestIdx: Int?
    let worstT: TimeInterval

    private let chartH: CGFloat = 96

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                let h = chartH
                // Y axis runs from 0 to slowest lap. Headroom (1.05) keeps
                // the worst lap from sticking to the top edge.
                let span = max(0.001, worstT * 1.05)
                let xs: [CGFloat] = laps.indices.map { i in
                    laps.count <= 1 ? w / 2 : CGFloat(i) / CGFloat(laps.count - 1) * w
                }
                let ys: [CGFloat] = laps.map { lap in
                    // Higher (smaller y) = faster lap.
                    h - CGFloat(lap.time / span) * h
                }

                ZStack(alignment: .topLeading) {
                    // Baseline rule
                    Rectangle()
                        .fill(EditorialTheme.hair)
                        .frame(height: 0.5)
                        .offset(y: h - 0.5)

                    // Connecting line
                    Path { path in
                        guard let first = xs.first, let firstY = ys.first else { return }
                        path.move(to: CGPoint(x: first, y: firstY))
                        for i in 1..<xs.count {
                            path.addLine(to: CGPoint(x: xs[i], y: ys[i]))
                        }
                    }
                    .stroke(EditorialTheme.ink.opacity(0.55), style: StrokeStyle(lineWidth: 1, lineJoin: .round))

                    // Lap dots — best gets accent + ring
                    ForEach(Array(laps.enumerated()), id: \.element.id) { i, _ in
                        let isBest = i == bestIdx
                        Circle()
                            .fill(isBest ? EditorialTheme.accent : EditorialTheme.ink)
                            .frame(width: isBest ? 7 : 4.5, height: isBest ? 7 : 4.5)
                            .overlay(
                                Circle().stroke(EditorialTheme.paper, lineWidth: isBest ? 1.5 : 1)
                            )
                            .position(x: xs[i], y: ys[i])
                    }
                }
            }
            .frame(height: chartH)

            // Lap-number axis
            GeometryReader { geo in
                let w = geo.size.width
                let xs: [CGFloat] = laps.indices.map { i in
                    laps.count <= 1 ? w / 2 : CGFloat(i) / CGFloat(laps.count - 1) * w
                }
                ForEach(Array(laps.enumerated()), id: \.element.id) { i, lap in
                    let isBest = i == bestIdx
                    Text(String(format: "%02d", lap.id))
                        .font(.editorialMono(8.5))
                        .monospacedDigit()
                        .foregroundStyle(isBest ? EditorialTheme.accent : EditorialTheme.sub)
                        .position(x: xs[i], y: 6)
                }
            }
            .frame(height: 12)
        }
    }
}
