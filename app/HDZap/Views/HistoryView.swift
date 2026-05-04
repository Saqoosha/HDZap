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
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.dateFormatter.string(from: record.startedAt))
                    .font(.editorialMono(13, weight: .medium))
                    .foregroundStyle(EditorialTheme.ink)
                Text(Self.timeFormatter.string(from: record.startedAt) +
                     " · \(Int(record.sessionLimit))s window")
                    .monoCap(size: 9, tracking: 1.4, color: EditorialTheme.sub)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(record.lapCount)L · \(EditorialFormat.time(record.totalTime, msDigits: 2))")
                    .font(.editorialMono(13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(EditorialTheme.ink)
                if let best = record.bestLapTime {
                    HStack(spacing: 4) {
                        Text("BEST")
                            .monoCap(size: 8.5, tracking: 1.4, color: EditorialTheme.sub)
                        Text(EditorialFormat.timeShort(best))
                            .font(.editorialMono(11))
                            .monospacedDigit()
                            .foregroundStyle(accent)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("Hm")
        return f
    }()
}
