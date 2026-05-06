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
                        .accessibilityLabel("More")
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
            .alert(
                "Save Failed",
                isPresented: Binding(
                    get: { history.lastPersistError != nil },
                    set: { if !$0 { history.clearLastPersistError() } }
                ),
                presenting: history.lastPersistError
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { msg in
                Text(msg)
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
            if let setupError = history.setupError {
                Text(setupError)
                    .font(.editorialMono(10))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
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
    /// The accent stored *with the race* — the row should re-create the
    /// look the operator saw at the time, not paint with whatever hue
    /// they happen to have selected today.
    private var accent: Color { EditorialTheme.accent(hue: record.accentHue) }

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
                        .frame(width: Self.bestColumnWidth, alignment: .trailing)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
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

                MiniLapTrendChart(laps: record.laps,
                                  bestIndex: record.bestLapIndex,
                                  bestColor: accent,
                                  height: 28)
                    .frame(maxWidth: .infinity)
                    .padding(.leading, 4)
                    .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }

                if let best = record.bestLapTime {
                    Text(EditorialFormat.timeShort(best))
                        .font(.editorialMono(18, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(accent)
                        .frame(width: Self.bestColumnWidth, alignment: .trailing)
                }
            }

            Text(RaceFormat.rowCaption.string(from: record.startedAt))
                .monoCap(size: 9.5, tracking: 1.4, color: EditorialTheme.sub)
        }
        .padding(.vertical, 6)
    }

    /// Pinned-trailing column width so the "Best" caption sits directly
    /// above its value across rows of varying laps/total digit counts.
    private static let bestColumnWidth: CGFloat = 64
}

/// Horizontal sparkline of lap times — one polyline through every lap,
/// best lap dot in the race's stored accent. Top of the plot = slowest,
/// bottom = fastest; a flat line reads as consistent pace, a spike as a
/// slow lap.
private struct MiniLapTrendChart: View {
    let laps: [RaceRecord.LapEntry]
    let bestIndex: Int?
    let bestColor: Color
    let height: CGFloat

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let pad: CGFloat = 4
            let plotH = max(0, h - pad * 2)
            let times = laps.map(\.time)
            let minT = times.min() ?? 0
            let maxT = times.max() ?? 0
            let range = maxT - minT
            let hasVariation = range > 0.001

            // Single y-mapping shared by the polyline and the dots so an
            // all-equal-laps run lands them on the same horizontal line
            // instead of the line jumping to the top while the dots
            // center themselves.
            let yFor: (TimeInterval) -> CGFloat = { t in
                hasVariation ? pad + CGFloat((maxT - t) / range) * plotH
                             : pad + plotH / 2
            }

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(EditorialTheme.hair)
                    .frame(height: 0.5)
                    .offset(y: h - 0.5)

                if times.count >= 2 {
                    Path { path in
                        for (i, t) in times.enumerated() {
                            let x = CGFloat(i) / CGFloat(times.count - 1) * w
                            let y = yFor(t)
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
                    let isBest: Bool = {
                        if let bestIndex { return i == bestIndex }
                        return false
                    }()
                    Circle()
                        .fill(isBest ? bestColor : EditorialTheme.ink)
                        .frame(width: isBest ? 5 : 2.5,
                               height: isBest ? 5 : 2.5)
                        .position(x: x, y: yFor(t))
                }
            }
        }
        .frame(height: height)
    }
}
