import SwiftUI
import os

/// Full read-out for a single saved race. Renders the same `RaceShareCard`
/// layout the operator saw post-race, plus toolbar actions for share /
/// delete. Looked up by id every body eval so a delete from the list
/// returns the user to the list with the row already gone.
struct RaceDetailView: View {
    let recordID: UUID
    /// When set, the view renders this record directly instead of
    /// looking it up in history. Used by the Settings → Debug → Voltage
    /// chart preview path so the editorial layout can be eyeballed
    /// without polluting the saved-race history. Toolbar share / delete
    /// are hidden in this mode (no real persisted record to act on).
    private let previewRecord: RaceRecord?
    @Environment(RaceHistoryStore.self) private var history
    @Environment(\.dismiss) private var dismiss

    @State private var shareItem: ShareItem?
    @State private var lastShareURL: URL?
    @State private var batteryShareItem: ShareItem?
    @State private var lastBatteryShareURL: URL?
    @State private var shareError: String?
    @State private var pendingDelete = false

    init(recordID: UUID) {
        self.recordID = recordID
        self.previewRecord = nil
    }

    /// Preview-only constructor for the Settings → Debug entry. The
    /// `recordID` parameter is set to `previewRecord.id` so toolbar
    /// actions that key off the lookup still target the right object
    /// shape (they're hidden in preview mode anyway).
    init(previewRecord: RaceRecord) {
        self.recordID = previewRecord.id
        self.previewRecord = previewRecord
    }

    private var record: RaceRecord? {
        if let previewRecord { return previewRecord }
        return history.records.first(where: { $0.id == recordID })
    }

    /// True when the view was constructed via the preview init — used
    /// to gate the toolbar (no share/delete on a synthetic record) and
    /// the auto-dismiss when the record disappears (the synthetic one
    /// never appears in history, so the dismiss check would always fire).
    private var isPreview: Bool { previewRecord != nil }

    var body: some View {
        Group {
            if let record {
                content(for: record)
            } else {
                // Placeholder while the dismiss fires (the .onChange below
                // owns the dismiss — `EmptyView().onAppear { dismiss() }`
                // didn't fire reliably because EmptyView is structural and
                // doesn't materialise lifecycle events).
                Color.clear
            }
        }
        .background(EditorialTheme.paper.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(navigationTitle)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let record, !isPreview {
                    if !record.flightBatterySamples.isEmpty {
                        Button(action: { shareBatteryCsvAction(record) }) {
                            Image(systemName: "battery.100percent")
                        }
                        .accessibilityLabel("Share flight battery CSV")
                    }
                    Button(action: shareAction) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share")
                    Button(role: .destructive, action: { pendingDelete = true }) {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Delete")
                }
            }
        }
        // Auto-dismiss when the record disappears (swipe-delete from the
        // list while detail is on screen). Driven by `.onChange` instead
        // of an EmptyView lifecycle hook so it actually fires. Preview
        // mode skips this — the synthetic record never lives in history
        // so the check would always be true.
        .onChange(of: record == nil) { _, isGone in
            if isGone && !isPreview { dismiss() }
        }
        // Defensive cleanup — if the user navigates back while the
        // share sheet is still open, SwiftUI may not deliver the
        // sheet's `onDismiss`, leaving the temp PNG stranded. The
        // helper is idempotent (no-op once `lastShareURL` is nil).
        .onDisappear {
            cleanupShareTempFile()
            cleanupBatteryCsvTempFile()
        }
        .sheet(item: $shareItem, onDismiss: cleanupShareTempFile) { item in
            ShareSheet(url: item.url)
        }
        .sheet(item: $batteryShareItem, onDismiss: cleanupBatteryCsvTempFile) { item in
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
        .alert("Delete this race?", isPresented: $pendingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                history.delete(id: recordID)
                dismiss()
            }
        } message: {
            Text("This permanently removes this saved race.")
        }
    }

    private var navigationTitle: String {
        guard let record else { return "" }
        return RaceFormat.detailTitle.string(from: record.startedAt)
    }

    @ViewBuilder
    private func content(for record: RaceRecord) -> some View {
        let inputs = renderInputs(for: record)
        let hasBattery = !record.flightBatterySamples.isEmpty
        ScrollView {
            // Suppress the card's own footer when there's a battery
            // section to insert between the lap table and the wordmark
            // — the footer is then re-rendered below the chart so it
            // anchors the bottom of the screen, not the middle. With
            // no battery samples, the card's built-in footer stays on
            // and the layout is identical to before this change.
            RaceShareCard(
                laps: inputs.laps,
                bestLapIndex: record.bestLapIndex,
                metrics: inputs.metrics,
                accentHue: record.accentHue,
                targetLapCount: record.targetLapCount,
                sessionLimit: record.sessionLimit,
                generatedAt: record.endedAt,
                includesFooter: !hasBattery
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            .padding(.bottom, hasBattery ? 0 : 12)

            if hasBattery {
                // Constrain the chart + footer to the same fixed
                // 393-pt card width as RaceShareCard so the chart's
                // edges line up with the lap table above on screens
                // wider than the card (e.g. iPhone Air at ~430 pt).
                // The 24-pt horizontal padding then matches the
                // card's internal column gutter, not the screen edge.
                flightBatterySection(record)
                    .padding(.horizontal, 24)
                    .padding(.top, 22)
                    .frame(width: RaceShareCard.width)
                    .frame(maxWidth: .infinity)

                RaceShareCardFooter(generatedAt: record.endedAt)
                    .padding(.horizontal, 24)
                    .padding(.top, 22)
                    .padding(.bottom, 24)
                    .frame(width: RaceShareCard.width)
                    .frame(maxWidth: .infinity)
            }
        }
        .scrollIndicators(.hidden)
        .environment(\.accentHue, record.accentHue)
    }

    /// The race is over, so pace equals achieved laps — no remaining
    /// session time to project additional laps into. Single source of
    /// truth so the on-screen card and the shared PNG can't drift if
    /// one site is later tweaked and the other isn't.
    private func renderInputs(for record: RaceRecord) -> (laps: [Lap], metrics: RaceMetrics?) {
        let laps = record.displayLaps
        let metrics = RaceMetrics(laps: laps,
                                  targetLapCount: record.targetLapCount,
                                  sessionLimit: record.sessionLimit,
                                  paceOverride: laps.count)
        return (laps, metrics)
    }

    // MARK: - Actions

    private func shareAction() {
        guard let record else { return }
        cleanupShareTempFile()
        do {
            let inputs = renderInputs(for: record)
            let url = try RaceShareCard.renderImage(
                laps: inputs.laps,
                bestLapIndex: record.bestLapIndex,
                metrics: inputs.metrics,
                accentHue: record.accentHue,
                targetLapCount: record.targetLapCount,
                sessionLimit: record.sessionLimit,
                generatedAt: record.endedAt
            )
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

    private func cleanupBatteryCsvTempFile() {
        if let url = lastBatteryShareURL {
            ShareImageError.cleanupTempFile(at: url, log: Self.log)
            lastBatteryShareURL = nil
        }
    }

    @ViewBuilder
    private func flightBatterySection(_ record: RaceRecord) -> some View {
        let samples = record.flightBatterySamples
        VStack(alignment: .leading, spacing: 10) {
            // Section header — "VBAT" + sample count, mirrors the
            // editorial caption pattern used in TimerView's masthead.
            HStack(alignment: .firstTextBaseline) {
                Text("VBAT").monoCap(size: 9.5, tracking: 2.0)
                Rectangle()
                    .fill(EditorialTheme.hair)
                    .frame(height: 0.5)
                Text("\(samples.count) samples")
                    .monoCap(size: 8.5, tracking: 1.5, color: EditorialTheme.dim)
            }

            voltageCaptionRow(samples: samples)

            VoltageTrendChart(
                samples: samples,
                sessionLimit: TimeInterval(record.sessionLimit),
                lapEndTimes: cumulativeLapEndTimes(record.laps)
            )
            .frame(height: 120)
            .environment(\.accentHue, record.accentHue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func voltageCaptionRow(samples: [RaceFlightBatterySample]) -> some View {
        let first = samples.first
        let last = samples.last
        let vStart = first?.voltageVolts ?? 0
        let vEnd = last?.voltageVolts ?? 0
        let vMin = samples.map(\.voltageVolts).min() ?? vEnd
        HStack(alignment: .firstTextBaseline, spacing: 22) {
            captionItem(label: "Start", value: String(format: "%.2f V", vStart))
            captionItem(label: "Min", value: String(format: "%.2f V", vMin), accent: true)
            captionItem(label: "End", value: String(format: "%.2f V", vEnd))
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func captionItem(label: String, value: String, accent: Bool = false) -> some View {
        // Accent only on the MIN entry — same role as the LapTrendChart's
        // best-lap accent dot. Reads as "this is the value you watch".
        VStack(alignment: .leading, spacing: 2) {
            Text(label).monoCap(size: 8, tracking: 1.5)
            Text(value)
                .font(.editorialMono(13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(accent
                                 ? AnyShapeStyle(EditorialTheme.accent(hue: previewAccentHue))
                                 : AnyShapeStyle(EditorialTheme.ink))
        }
    }

    /// Cumulative lap end times for the voltage chart's lap-marker
    /// vertical lines. Each entry is the wall-clock-since-start at
    /// which lap N ended (= sum of laps[0...N].time). The last entry
    /// often equals or exceeds sessionLimit when a final lap straddles
    /// the buzzer; the chart clips off-axis values.
    private func cumulativeLapEndTimes(_ laps: [RaceRecord.LapEntry]) -> [TimeInterval] {
        var running: TimeInterval = 0
        return laps.map { lap in
            running += lap.time
            return running
        }
    }

    /// The accent hue for caption coloring mirrors the record's own.
    /// Looked up via the record because `@Environment(\.accentHue)` would
    /// reach for the parent (Settings) accent when this view is rendered
    /// from the demo preview entry.
    private var previewAccentHue: Double {
        record?.accentHue ?? EditorialTheme.defaultAccentHue
    }

    /// Writes `record.flightBatteryCSVText()` to a temp `.csv` and opens the share sheet.
    private func shareBatteryCsvAction(_ record: RaceRecord) {
        cleanupBatteryCsvTempFile()
        let csv = record.flightBatteryCSVText()
        guard !csv.isEmpty else { return }
        let base = RaceFormat.detailTitle.string(from: record.startedAt)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let name = "HDZap-battery-\(base).csv"
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = dir.appendingPathComponent(name)
        guard let data = csv.data(using: .utf8) else {
            shareError = "Couldn't encode battery CSV as UTF-8."
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            lastBatteryShareURL = url
            batteryShareItem = ShareItem(url: url)
        } catch {
            shareError = "Couldn't write battery CSV (\(error.localizedDescription))."
        }
    }

    private static let log = Logger(subsystem: "sh.saqoo.HDZap", category: "RaceDetailView")
}

// MARK: - VoltageTrendChart

/// Editorial flight-pack voltage trace — race time on X (0 → sessionLimit
/// with 10-s tick marks matching the live sessionBar), voltage on Y with
/// auto-padded range. Hand-drawn `Path` so the visual language matches
/// `LapTrendChartVertical`. Dots at every sample, accent + larger dot at
/// the min-voltage point (analogous to the best-lap marker in the lap
/// chart). Extracts a min-voltage label inline at the chart edge so the
/// reader can locate the dip without cross-referencing the caption row.
struct VoltageTrendChart: View {
    let samples: [RaceFlightBatterySample]
    let sessionLimit: TimeInterval
    /// Cumulative race time at which each lap ended. Drawn as vertical
    /// hairlines through the full plot height so the operator can read
    /// "voltage at lap 3 boundary". Empty array hides the markers
    /// entirely. Out-of-axis values (last lap straddling the buzzer)
    /// are clipped by the chart's plot rect.
    let lapEndTimes: [TimeInterval]
    @Environment(\.accentHue) private var accentHue: Double

    var body: some View {
        GeometryReader { geo in
            let chart = chartGeometry(in: geo.size)
            ZStack(alignment: .topLeading) {
                // Lap end markers — full-height vertical hairlines so
                // the voltage at each lap boundary can be read off the
                // trace. `hairStrong` (18 % ink) so they're more
                // structural than the per-10-s tick marks below but
                // still recede behind the data trace itself.
                ForEach(Array(lapEndTimes.enumerated()), id: \.offset) { _, t in
                    if t > 0 && t <= sessionLimit {
                        Rectangle()
                            .fill(EditorialTheme.hairStrong)
                            .frame(width: 0.5, height: chart.plotBottom)
                            .offset(x: chart.x(forTRace: t), y: 0)
                    }
                }

                // X axis hairline at the bottom — same hair-strong weight
                // as the sessionBar progress bar's outer rule.
                Rectangle()
                    .fill(EditorialTheme.hairStrong)
                    .frame(height: 0.5)
                    .offset(y: chart.plotBottom)

                // 10-s tick marks. Skip 0 and sessionLimit since the X
                // labels at the bottom anchor those edges visually.
                ForEach(Array(stride(from: 10, to: Int(sessionLimit), by: 10)), id: \.self) { sec in
                    Rectangle()
                        .fill(EditorialTheme.hair)
                        .frame(width: 0.5, height: 5)
                        .offset(x: chart.x(forTRace: TimeInterval(sec)),
                                y: chart.plotBottom - 5)
                }

                if samples.count >= 2 {
                    Path { path in
                        for (i, s) in samples.enumerated() {
                            let p = CGPoint(x: chart.x(forTRace: s.tRace),
                                            y: chart.y(forVolts: s.voltageVolts))
                            if i == 0 {
                                path.move(to: p)
                            } else {
                                path.addLine(to: p)
                            }
                        }
                    }
                    .stroke(EditorialTheme.ink.opacity(0.7),
                            style: StrokeStyle(lineWidth: 1, lineJoin: .round))
                }

                // Key by enumeration offset rather than `receivedAt` —
                // sub-millisecond Date collisions are practically
                // impossible at CRSF's 0.25 Hz cadence in production,
                // but the synthetic-record preview can produce exactly-
                // colliding timestamps via integer-second `addingTimeInterval`,
                // and SwiftUI silently drops the duplicate dot when ids
                // collide.
                ForEach(Array(samples.enumerated()), id: \.offset) { _, s in
                    let isMin = s.voltageVolts == chart.vMin
                    let p = CGPoint(x: chart.x(forTRace: s.tRace),
                                    y: chart.y(forVolts: s.voltageVolts))
                    Circle()
                        .fill(isMin ? EditorialTheme.accent(hue: accentHue)
                                    : EditorialTheme.ink)
                        .frame(width: isMin ? 7 : 3.5,
                               height: isMin ? 7 : 3.5)
                        .overlay(
                            Circle().stroke(EditorialTheme.paper,
                                            lineWidth: isMin ? 1.5 : 0.75)
                        )
                        .position(x: p.x, y: p.y)
                }

                // X-axis time labels — 0 / mid / end. Match the
                // sessionBar's "0 / N/2 / N" pattern.
                HStack {
                    Text("0").monoCap(size: 8, tracking: 1.5)
                    Spacer()
                    Text("\(Int(sessionLimit / 2))s").monoCap(size: 8, tracking: 1.5)
                    Spacer()
                    Text("\(Int(sessionLimit))s").monoCap(size: 8, tracking: 1.5)
                }
                .frame(width: geo.size.width)
                .offset(y: chart.plotBottom + 4)
            }
        }
    }

    /// Cached layout + Y-range maths so the body doesn't recompute three
    /// times across path / dots / labels.
    private func chartGeometry(in size: CGSize) -> ChartGeometry {
        let voltages = samples.map(\.voltageVolts)
        let rawMin = voltages.min() ?? 0
        let rawMax = voltages.max() ?? rawMin + 0.5
        // Pad the Y range so the trace doesn't kiss the chart edges
        // (otherwise the min dot's accent halo gets clipped). Min span
        // of 0.5 V keeps a near-flat trace from drawing as a single
        // pixel-thick line.
        let span = max(0.5, rawMax - rawMin)
        let pad = span * 0.10
        let yMax = rawMax + pad
        let yMin = rawMin - pad
        // Reserve 18 pt at the bottom for the X labels.
        let plotBottom = size.height - 18
        return ChartGeometry(
            size: size,
            plotBottom: plotBottom,
            sessionLimit: sessionLimit,
            yMin: yMin,
            yMax: yMax,
            vMin: rawMin
        )
    }

    private struct ChartGeometry {
        let size: CGSize
        let plotBottom: CGFloat
        let sessionLimit: TimeInterval
        let yMin: Double
        let yMax: Double
        /// Raw (un-padded) min voltage, for matching dots against the
        /// "accent" rule in body. Equality vs the padded yMin would be
        /// off-by-pad and miss the actual min sample.
        let vMin: Double

        func x(forTRace tRace: TimeInterval) -> CGFloat {
            let span = max(0.001, sessionLimit)
            let frac = max(0, min(1, tRace / span))
            return CGFloat(frac) * size.width
        }

        func y(forVolts v: Double) -> CGFloat {
            let span = max(0.001, yMax - yMin)
            let frac = max(0, min(1, (yMax - v) / span))
            return CGFloat(frac) * plotBottom
        }
    }
}
