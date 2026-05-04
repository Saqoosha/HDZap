import SwiftUI
import os

/// Full read-out for a single saved race. Renders the same `RaceShareCard`
/// layout the operator saw post-race, plus toolbar actions for share /
/// delete. Looked up by id every body eval so a delete from the list
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
                if record != nil {
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
        // of an EmptyView lifecycle hook so it actually fires.
        .onChange(of: record == nil) { _, isGone in
            if isGone { dismiss() }
        }
        // Defensive cleanup — if the user navigates back while the
        // share sheet is still open, SwiftUI may not deliver the
        // sheet's `onDismiss`, leaving the temp PNG stranded. The
        // helper is idempotent (no-op once `lastShareURL` is nil).
        .onDisappear { cleanupShareTempFile() }
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
        return RaceFormat.detailTitle.string(from: record.startedAt)
    }

    @ViewBuilder
    private func content(for record: RaceRecord) -> some View {
        let inputs = renderInputs(for: record)
        ScrollView {
            RaceShareCard(
                laps: inputs.laps,
                bestLapIndex: record.bestLapIndex,
                metrics: inputs.metrics,
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

    private static let log = Logger(subsystem: "sh.saqoo.HDZap", category: "RaceDetailView")
}
