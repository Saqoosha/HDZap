import SwiftUI

/// Standalone snapshot view rendered offscreen via `ImageRenderer` to produce
/// the PNG that the share sheet hands off. Mirrors `TimerView`'s post-race
/// layout — same paddings, row heights, summary band, and hero typography —
/// so the shared image reads as the screen the operator was watching, plus a
/// card-only header/footer for context once the masthead and action dock are
/// stripped.
///
/// Width matches a typical iPhone (393pt) so `ImageRenderer.scale = 3` yields
/// a 1179px PNG with the same aspect ratio as the device. Bumping the width
/// in isolation makes the card look "too wide" vs. the screen because the
/// internal column widths and row heights stay the same — keep this aligned
/// with `TimerView` if you change either side.
struct RaceShareCard: View {
    let laps: [Lap]
    let bestLapIndex: Int?
    let metrics: RaceMetrics?
    let accentHue: Double
    let targetLapCount: Int
    let sessionLimit: TimeInterval
    let generatedAt: Date

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

    private var clampedTargetLapCount: Int {
        RaceMetrics.clampedTargetLapCount(targetLapCount)
    }

    private var targetSummaryValue: String {
        let targetLapSec = RaceMetrics.targetLapSeconds(for: clampedTargetLapCount,
                                                        sessionLimit: sessionLimit)
        return "\(clampedTargetLapCount)L@\(RaceMetrics.seconds(targetLapSec, decimals: 2))"
    }

    var body: some View {
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

            lapHeader
                .padding(.horizontal, 24)
                .padding(.top, 16)

            lapRowsWithTrend
                .padding(.horizontal, 24)
                .padding(.top, 4)

            footer
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 24)
        }
        .frame(width: Self.width)
        .background(EditorialTheme.paper)
        .environment(\.accentHue, accentHue)
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
        if laps.isEmpty {
            Text("No laps")
                .monoCap(size: 11, tracking: 1.2, color: EditorialTheme.dim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else {
            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: 0) {
                    ForEach(Array(laps.enumerated().reversed()), id: \.element.id) { realIdx, lap in
                        let isBest = realIdx == bestLapIndex
                        let delta = (bestTime ?? 0) > 0 ? lap.time - (bestTime ?? 0) : 0
                        EditorialLapRow(lap: lap, isBest: isBest, delta: delta,
                                        height: Self.lapRowHeight)
                    }
                }
                .frame(maxWidth: .infinity)

                LapTrendChartVertical(
                    laps: laps,
                    bestIdx: bestLapIndex,
                    worstT: worstTime ?? 0,
                    rowHeight: Self.lapRowHeight
                )
                .frame(width: Self.trendColumnWidth)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(Self.timestampFormatter.string(from: generatedAt))
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

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
