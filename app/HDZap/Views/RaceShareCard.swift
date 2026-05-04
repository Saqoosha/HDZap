import SwiftUI
import UIKit

/// Standalone snapshot view rendered offscreen via `ImageRenderer` for the
/// share sheet. Mirrors `TimerView`'s post-race layout (paddings, row
/// heights, typography) so the shared image reads as the screen the operator
/// was watching; the masthead, session bar, action dock, and BLE/error
/// strips are dropped because they carry no meaning post-race, replaced by a
/// card-only header (HDZap masthead substitute) and footer (timestamp +
/// wordmark) for context.
///
/// Width is fixed at 393pt (iPhone 15 width) so `ImageRenderer.scale = 3`
/// in `TimerView.makeShareImage()` yields a 1179px-wide PNG. The lap-table
/// geometry is sourced from `LapTableMetrics` and the lap header/body from
/// `LapTableHeader`/`LapTable`, so widening the card requires either
/// scaling those constants in proportion or extracting more of the shared
/// layout — bumping `width` in isolation reverts to the original "too wide"
/// regression. The `doneBlock` and `summaryBand` typography below are still
/// duplicated against `TimerView` (64pt hero, 22pt ms suffix, monoCap(9))
/// and must be kept in sync by hand until promoted to a shared view.
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

            LapTableHeader()
                .padding(.horizontal, 24)
                .padding(.top, 16)

            LapTable(laps: laps,
                     bestLapIndex: bestLapIndex,
                     bestTime: bestTime,
                     worstTime: worstTime)
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
                            generatedAt: Date) throws -> URL {
        let card = RaceShareCard(
            laps: laps,
            bestLapIndex: bestLapIndex,
            metrics: metrics,
            accentHue: accentHue,
            targetLapCount: targetLapCount,
            sessionLimit: sessionLimit,
            generatedAt: generatedAt
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
