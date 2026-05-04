import SwiftUI

/// Browse, share, and delete past races. Presented as a sheet from the
/// masthead clock icon. List is fed by `RaceHistoryStore`; rows push to
/// `RaceDetailView` for the full per-race read-out.
struct HistoryView: View {
    @Environment(RaceHistoryStore.self) private var history
    @Environment(\.dismiss) private var dismiss
    @State private var pendingClearAll = false

    var body: some View {
        NavigationStack {
            Group {
                if history.records.isEmpty {
                    emptyState
                } else {
                    raceList
                }
            }
            .background(EditorialTheme.paper.ignoresSafeArea())
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if !history.records.isEmpty {
                        Menu {
                            Button("Clear All", role: .destructive) {
                                pendingClearAll = true
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .alert("Delete all races?", isPresented: $pendingClearAll) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    history.deleteAll()
                }
            } message: {
                Text("This permanently removes every saved race.")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "flag.checkered")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(EditorialTheme.dim)
            Text("No races yet")
                .monoCap(size: 11, tracking: 1.6, color: EditorialTheme.sub)
            Text("Finish a race and it'll show up here.")
                .font(.editorialMono(11))
                .foregroundStyle(EditorialTheme.dim)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var raceList: some View {
        List {
            ForEach(history.records) { record in
                NavigationLink {
                    RaceDetailView(recordID: record.id)
                } label: {
                    HistoryRow(record: record)
                }
                .listRowBackground(EditorialTheme.paper)
            }
            .onDelete { offsets in
                let ids = offsets.map { history.records[$0].id }
                for id in ids { history.delete(id: id) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

private struct HistoryRow: View {
    let record: RaceRecord
    @Environment(\.accentHue) private var accentHue: Double
    private var accent: Color { EditorialTheme.accent(hue: accentHue) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Three columns: Laps · Trend · Best. The trend column flexes
            // so the chart butts right up against the total time and
            // stretches across the unused space; only Best is pinned to a
            // fixed trailing width.
            HStack(spacing: 8) {
                Text("Laps")
                    .monoCap(size: 9, tracking: 2.0, color: EditorialTheme.sub)
                Text("Trend")
                    .monoCap(size: 9, tracking: 2.0, color: EditorialTheme.sub)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
                if record.bestLapTime != nil {
                    Text("Best")
                        .monoCap(size: 9, tracking: 2.0, color: EditorialTheme.sub)
                        .frame(width: bestColumnWidth, alignment: .trailing)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Column 1: lap count + total time.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(record.lapCount)")
                            .font(.editorialDisplay(28, weight: .light))
                            .monospacedDigit()
                            .tracking(-0.8)
                            .foregroundStyle(EditorialTheme.ink)
                        Text("L")
                            .font(.editorialMono(13, weight: .medium))
                            .foregroundStyle(EditorialTheme.sub)
                    }
                    Text(EditorialFormat.time(record.totalTime, msDigits: 2))
                        .font(.editorialMono(18, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(EditorialTheme.ink)
                }

                // Column 2: sparkline — flexes to fill the gap.
                MiniLapTrendChart(laps: record.laps,
                                  bestIndex: record.bestLapIndex,
                                  height: 28)
                    .frame(maxWidth: .infinity)
                    .padding(.leading, 4)
                    .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }

                // Column 3: best lap time.
                if let best = record.bestLapTime {
                    Text(EditorialFormat.timeShort(best))
                        .font(.editorialMono(18, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(accent)
                        .frame(width: bestColumnWidth, alignment: .trailing)
                }
            }

            Text(Self.captionFormatter.string(from: record.startedAt))
                .monoCap(size: 9.5, tracking: 1.4, color: EditorialTheme.sub)
        }
        .padding(.vertical, 6)
    }

    /// Pinned-trailing column width so the "BEST" caption sits directly
    /// above its value across rows of varying laps/total digit counts.
    private var bestColumnWidth: CGFloat { 64 }

    private static let captionFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.autoupdatingCurrent
        // "Apr 5, 21:08" — date and clock time on one line, locale-aware.
        f.setLocalizedDateFormatFromTemplate("MMMdHm")
        return f
    }()
}

/// Horizontal sparkline of lap times — one polyline through every lap,
/// best lap dot in accent. Top of the plot = fastest, bottom = slowest;
/// a flat line reads as consistent pace, a spike reads as a slow lap.
private struct MiniLapTrendChart: View {
    let laps: [RaceRecord.LapEntry]
    let bestIndex: Int?
    let height: CGFloat
    @Environment(\.accentHue) private var accentHue: Double
    private var accent: Color { EditorialTheme.accent(hue: accentHue) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let pad: CGFloat = 4
            let plotH = max(0, h - pad * 2)
            let times = laps.map(\.time)
            let minT = times.min() ?? 0
            let maxT = times.max() ?? 0
            let range = max(0.001, maxT - minT)

            ZStack(alignment: .topLeading) {
                // Hairline rule along the bottom — origin reference.
                Rectangle()
                    .fill(EditorialTheme.hair)
                    .frame(height: 0.5)
                    .offset(y: h - 0.5)

                if times.count >= 2 {
                    Path { path in
                        for (i, t) in times.enumerated() {
                            let x = CGFloat(i) / CGFloat(times.count - 1) * w
                            let y = pad + CGFloat((t - minT) / range) * plotH
                            if i == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(EditorialTheme.ink.opacity(0.55),
                            style: StrokeStyle(lineWidth: 1, lineJoin: .round))
                }

                ForEach(Array(times.enumerated()), id: \.offset) { i, t in
                    let x = times.count <= 1
                        ? w / 2
                        : CGFloat(i) / CGFloat(times.count - 1) * w
                    let y = pad + (range > 0.001
                                   ? CGFloat((t - minT) / range) * plotH
                                   : plotH / 2)
                    let isBest = i == bestIndex
                    Circle()
                        .fill(isBest ? accent : EditorialTheme.ink)
                        .frame(width: isBest ? 5 : 2.5,
                               height: isBest ? 5 : 2.5)
                        .position(x: x, y: y)
                }
            }
        }
        .frame(height: height)
    }
}
