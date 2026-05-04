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
        ScrollView {
            RaceShareCard(
                laps: record.displayLaps,
                bestLapIndex: record.bestLapIndex,
                metrics: metrics(for: record),
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
    /// session time left to project additional laps into. Single source
    /// of truth so the on-screen card and the shared PNG can't diverge.
    private func metrics(for record: RaceRecord) -> RaceMetrics? {
        let laps = record.displayLaps
        return RaceMetrics(laps: laps,
                           targetLapCount: record.targetLapCount,
                           sessionLimit: record.sessionLimit,
                           paceOverride: laps.count)
    }

    // MARK: - Actions

    private func shareAction() {
        guard let record else { return }
        cleanupShareTempFile()
        do {
            let url = try RaceShareCard.renderImage(
                laps: record.displayLaps,
                bestLapIndex: record.bestLapIndex,
                metrics: metrics(for: record),
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
