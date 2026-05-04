import SwiftUI

/// Full read-out for a single saved race. Renders the same `RaceShareCard`
/// layout the operator saw post-race, plus toolbar actions for share /
/// delete. Looked up by id every body eval so a delete from the toolbar
/// returns the user to the list with the row already gone.
struct RaceDetailView: View {
    let recordID: UUID
    @Environment(RaceHistoryStore.self) private var history
    @Environment(\.dismiss) private var dismiss

    @State private var shareItem: ShareItem?
    @State private var lastShareURL: URL?
    @State private var shareError: String?
    @State private var pendingDelete = false

    private var record: RaceRecord? {
        history.records.first(where: { $0.id == recordID })
    }

    var body: some View {
        Group {
            if let record {
                content(for: record)
            } else {
                // Record was deleted (likely via swipe on the list while
                // this detail was on screen) — show a brief placeholder
                // until the dismiss fires, since `onAppear` doesn't run
                // again on an already-mounted view.
                EmptyView()
                    .onAppear { dismiss() }
            }
        }
        .background(EditorialTheme.paper.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(navigationTitle)
        .toolbar {
            if record != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: shareAction) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive, action: { pendingDelete = true }) {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Delete")
                }
            }
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
        return Self.titleFormatter.string(from: record.startedAt)
    }

    @ViewBuilder
    private func content(for record: RaceRecord) -> some View {
        let laps = record.displayLaps
        let metrics = RaceMetrics(
            laps: laps,
            targetLapCount: record.targetLapCount,
            sessionLimit: record.sessionLimit,
            // Pace at race-end equals the achieved lap count — same value
            // `TimerView.secondaryAction()` uses on manual STOP, so the
            // detail view reads identically to the post-race summary.
            paceOverride: laps.count
        )
        ScrollView {
            RaceShareCard(
                laps: laps,
                bestLapIndex: record.bestLapIndex,
                metrics: metrics,
                accentHue: record.accentHue,
                targetLapCount: record.targetLapCount,
                sessionLimit: record.sessionLimit,
                generatedAt: record.endedAt
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .environment(\.accentHue, record.accentHue)
    }

    // MARK: - Actions

    private func shareAction() {
        guard let record else { return }
        cleanupShareTempFile()
        do {
            let laps = record.displayLaps
            let metrics = RaceMetrics(laps: laps,
                                      targetLapCount: record.targetLapCount,
                                      sessionLimit: record.sessionLimit,
                                      paceOverride: laps.count)
            let url = try RaceShareCard.renderImage(
                laps: laps,
                bestLapIndex: record.bestLapIndex,
                metrics: metrics,
                accentHue: record.accentHue,
                targetLapCount: record.targetLapCount,
                sessionLimit: record.sessionLimit,
                generatedAt: record.endedAt
            )
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

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("MMMdHm")
        return f
    }()
}
