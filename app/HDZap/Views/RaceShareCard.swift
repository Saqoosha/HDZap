import SwiftUI

/// Standalone snapshot view rendered offscreen via `ImageRenderer` to produce
/// the PNG that the share sheet hands off. Mirrors the on-screen result layout
/// (doneBlock + summary band + lap list + trend sparkline) but excludes the
/// masthead, session bar, action dock, and BLE/error strips — those carry no
/// meaning once the race is over.
///
/// Fixed 1080pt width so `ImageRenderer.scale = 3` yields a 3240px PNG that
/// looks crisp on retina displays regardless of which device the user shared
/// from.
struct RaceShareCard: View {
    let laps: [Lap]
    let bestLapIndex: Int?
    let metrics: RaceMetrics?
    let accentHue: Double
    let targetLapCount: Int
    let sessionLimit: TimeInterval
    let generatedAt: Date

    static let width: CGFloat = 1080

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
                .padding(.horizontal, 36)
                .padding(.top, 36)

            doneBlock
                .padding(.horizontal, 36)
                .padding(.top, 32)

            summaryBand
                .padding(.horizontal, 36)
                .padding(.top, 28)

            lapHeader
                .padding(.horizontal, 36)
                .padding(.top, 24)

            lapRowsWithTrend
                .padding(.horizontal, 36)
                .padding(.top, 4)

            footer
                .padding(.horizontal, 36)
                .padding(.top, 28)
                .padding(.bottom, 36)
        }
        .frame(width: Self.width)
        .background(EditorialTheme.paper)
        .environment(\.accentHue, accentHue)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("HDZap · Time Attack \(Int(sessionLimit))s")
                .monoCap(size: 12, tracking: 2.2, color: EditorialTheme.ink)
            Spacer()
            Text("Race Result")
                .monoCap(size: 12, tracking: 2.2, color: accent)
        }
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(EditorialTheme.ink).frame(height: 1)
        }
    }

    private var doneBlock: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: -4) {
                Text("Laps").monoCap(size: 11, tracking: 2.0, color: accent)
                Text(String(format: "%02d", laps.count))
                    .font(.editorialDisplay(96, weight: .light))
                    .monospacedDigit()
                    .tracking(-2)
                    .foregroundStyle(accent)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: -4) {
                Text("Total Time").monoCap(size: 11, tracking: 2.0)
                BigTime(seconds: totalTime,
                        accent: EditorialTheme.ink,
                        size: 96,
                        msSize: 32)
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
        .padding(.vertical, 14)
        .padding(.trailing, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(EditorialTheme.ink).frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(EditorialTheme.hair).frame(height: 0.5)
        }
    }

    private static let lapRowHeight: CGFloat = 56
    private static let trendColumnWidth: CGFloat = 220

    private var lapHeader: some View {
        HStack(spacing: 12) {
            Text("#").monoCap(size: 12, tracking: 1.6).frame(width: 36, alignment: .leading)
            Text("Split").monoCap(size: 12, tracking: 1.6).frame(maxWidth: .infinity, alignment: .leading)
            Text("Δ Best").monoCap(size: 12, tracking: 1.6).frame(width: 110, alignment: .trailing)
            Text("Trend").monoCap(size: 12, tracking: 1.6)
                .frame(width: Self.trendColumnWidth, alignment: .center)
        }
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(EditorialTheme.hair).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var lapRowsWithTrend: some View {
        if laps.isEmpty {
            Text("No laps")
                .monoCap(size: 13, tracking: 1.2, color: EditorialTheme.dim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
        } else {
            HStack(alignment: .top, spacing: 12) {
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
                .monoCap(size: 10, tracking: 1.6, color: EditorialTheme.dim)
            Spacer()
            Text("hdzap")
                .monoCap(size: 10, tracking: 1.6, color: EditorialTheme.dim)
        }
        .padding(.top, 10)
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
