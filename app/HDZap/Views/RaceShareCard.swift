import SwiftUI
import UIKit

/// Standalone snapshot view rendered offscreen via `ImageRenderer` for the
/// share sheet. Mirrors the post-race summary layout (paddings, row
/// heights, typography) so the shared image reads as the screen the operator
/// was watching; the masthead, session bar, action dock, and BLE/error
/// strips are dropped because they carry no meaning post-race, replaced by a
/// card-only header (wordmark substitute) and footer (timestamp + wordmark)
/// for context.
///
/// PNG export is locked at 393pt (iPhone 15 width) so a 3× ImageRenderer
/// scale yields a canonical 1179px-wide image regardless of host device.
/// On-screen the card stretches to fill the available width via
/// `.frame(maxWidth: .infinity)` so the detail view sits edge-to-edge
/// like the live timer instead of leaving extra margin on devices wider
/// than 393pt (iPhone Pro Max / iPhone Air) or clipping past the right
/// edge on devices narrower than 393pt (iPhone SE / mini at 375 pt).
/// The `mode` parameter selects between the two — see `body` below.
/// Lap-table geometry comes from `LapTableMetrics`; the fixed-width
/// #/Δ/Trend columns stay constant and the flexible Split column
/// absorbs the slack when the card stretches or narrows. Hero typography
/// (64pt display, 22pt ms suffix, monoCap(9)) is currently duplicated in
/// the live timer's done-block and must stay in sync until promoted to
/// a shared view.
struct RaceShareCard: View {
    /// Layout target. `.screen` fills the available width so the detail
    /// view goes edge-to-edge; `.pngExport` locks to `Self.width` so the
    /// rendered PNG geometry matches the iPhone 15 reference layout
    /// regardless of host device.
    enum RenderMode {
        case screen
        case pngExport
    }

    let laps: [Lap]
    let bestLapIndex: Int?
    let metrics: RaceMetrics?
    let accentHue: Double
    let targetLapCount: Int
    let sessionLimit: TimeInterval
    let generatedAt: Date
    var mode: RenderMode = .screen
    /// CRSF flight-pack battery samples captured during the race. Empty
    /// for races recorded before the telemetry pipeline existed (or any
    /// race where the bound TX wasn't sending battery telemetry); the
    /// VBAT section is hidden in that case. Both the on-screen detail
    /// view and the PNG export use the same view, so the share image
    /// includes the chart whenever the saved record has samples.
    var flightBatterySamples: [RaceFlightBatterySample] = []

    static let width: CGFloat = 393

    private var accent: Color { EditorialTheme.accent(hue: accentHue) }

    private var bestTime: TimeInterval? {
        guard let i = bestLapIndex, laps.indices.contains(i) else { return nil }
        return laps[i].time
    }

    private var worstTime: TimeInterval? {
        laps.map(\.time).max()
    }

    private var avgTime: TimeInterval {
        guard !laps.isEmpty else { return 0 }
        return laps.reduce(0) { $0 + $1.time } / Double(laps.count)
    }

    private var totalTime: TimeInterval {
        laps.reduce(0) { $0 + $1.time }
    }

    /// Cumulative race-time at which each lap ended. Drives the lap-end
    /// hairlines on the voltage chart. Computed inline so the caller
    /// doesn't have to thread it through.
    private var lapEndTimes: [TimeInterval] {
        var running: TimeInterval = 0
        return laps.map { lap in
            running += lap.time
            return running
        }
    }

    private var clampedTargetLapCount: Int {
        RaceMetrics.clampedTargetLapCount(targetLapCount)
    }

    private var targetSummaryValue: String {
        let targetLapSec = RaceMetrics.targetLapSeconds(for: clampedTargetLapCount,
                                                        sessionLimit: sessionLimit)
        return "\(clampedTargetLapCount)L@\(RaceMetrics.seconds(targetLapSec, decimals: 2))"
    }

    var body: some View {
        let stack = cardStack
            .background(EditorialTheme.paper)
            .environment(\.accentHue, accentHue)
        switch mode {
        case .pngExport:
            stack.frame(width: Self.width)
        case .screen:
            stack.frame(maxWidth: .infinity)
        }
    }

    private var cardStack: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 24)

            doneBlock
                .padding(.horizontal, 24)
                .padding(.top, 20)

            summaryBand
                .padding(.horizontal, 24)
                .padding(.top, 18)

            LapTableHeader()
                .padding(.horizontal, 24)
                .padding(.top, 16)

            LapTable(laps: laps,
                     bestLapIndex: bestLapIndex,
                     bestTime: bestTime,
                     worstTime: worstTime,
                     chronological: true)
                .padding(.horizontal, 24)
                .padding(.top, 4)

            if !flightBatterySamples.isEmpty {
                RaceFlightBatterySection(
                    samples: flightBatterySamples,
                    lapEndTimes: lapEndTimes,
                    sessionLimit: sessionLimit,
                    accentHue: accentHue
                )
                .padding(.horizontal, 24)
                .padding(.top, 22)
            }

            // Footer sits closer to the lap table when there's no
            // chart between them; the chart already supplies its own
            // visual breathing room above the footer hairline.
            RaceShareCardFooter(generatedAt: generatedAt)
                .padding(.horizontal, 24)
                .padding(.top, flightBatterySamples.isEmpty ? 18 : 22)
                .padding(.bottom, 24)
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("HDZap · Time Attack \(Int(sessionLimit))s")
                .monoCap(size: 9.5, tracking: 2.0, color: EditorialTheme.ink)
            Spacer()
            Text("Race Result")
                .monoCap(size: 9.5, tracking: 2.0, color: accent)
        }
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(EditorialTheme.ink).frame(height: 1)
        }
    }

    private var doneBlock: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: -4) {
                Text("Laps").monoCap(size: 9, tracking: 2.0, color: accent)
                Text(String(format: "%02d", laps.count))
                    .font(.editorialDisplay(64, weight: .light))
                    .monospacedDigit()
                    .tracking(-2)
                    .foregroundStyle(accent)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: -4) {
                Text("Total Time").monoCap(size: 9, tracking: 2.0)
                BigTime(seconds: totalTime,
                        accent: EditorialTheme.ink,
                        size: 64,
                        msSize: 22)
            }
        }
    }

    private var summaryBand: some View {
        HStack(spacing: 0) {
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

    fileprivate static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// Render the card to a PNG in the temp directory and return its URL.
    /// Throws `ShareImageError` for renderer / encoder failures and rethrows
    /// the underlying `Data.write` error for I/O failures (out-of-space,
    /// permission), so the caller can map them to user-facing copy.
    @MainActor
    static func renderImage(laps: [Lap],
                            bestLapIndex: Int?,
                            metrics: RaceMetrics?,
                            accentHue: Double,
                            targetLapCount: Int,
                            sessionLimit: TimeInterval,
                            generatedAt: Date,
                            flightBatterySamples: [RaceFlightBatterySample] = []) throws -> URL {
        let card = RaceShareCard(
            laps: laps,
            bestLapIndex: bestLapIndex,
            metrics: metrics,
            accentHue: accentHue,
            targetLapCount: targetLapCount,
            sessionLimit: sessionLimit,
            generatedAt: generatedAt,
            mode: .pngExport,
            flightBatterySamples: flightBatterySamples
        )
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        guard let uiImage = renderer.uiImage else {
            throw ShareImageError.rendererProducedNoImage
        }
        guard let data = uiImage.pngData() else {
            throw ShareImageError.pngEncodeFailed
        }
        let stamp = fileTimestampFormatter.string(from: generatedAt)
        // Per-render UUID suffix prevents collisions when the user shares
        // multiple races within the same second (timestamp resolution is 1s).
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

/// Timestamp + "hdzap" wordmark caption with a hairline rule above.
/// Sits at the bottom of `RaceShareCard`, below the optional
/// flight-battery section.
struct RaceShareCardFooter: View {
    let generatedAt: Date

    var body: some View {
        HStack {
            Text(RaceShareCard.timestampFormatter.string(from: generatedAt))
                .monoCap(size: 8.5, tracking: 1.4, color: EditorialTheme.dim)
            Spacer()
            Text("hdzap")
                .monoCap(size: 8.5, tracking: 1.4, color: EditorialTheme.dim)
        }
        .padding(.top, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(EditorialTheme.hair).frame(height: 0.5)
        }
    }
}
