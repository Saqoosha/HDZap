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
    @State private var batteryShareItem: ShareItem?
    @State private var lastBatteryShareURL: URL?
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
                if let record {
                    if !record.flightBatterySamples.isEmpty {
                        Button(action: { shareBatteryCsvAction(record) }) {
                            Image(systemName: "battery.100percent")
                        }
                        .accessibilityLabel("Share flight battery CSV")
                    }
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
        .onDisappear {
            cleanupShareTempFile()
            cleanupBatteryCsvTempFile()
        }
        .sheet(item: $shareItem, onDismiss: cleanupShareTempFile) { item in
            ShareSheet(url: item.url)
        }
        .sheet(item: $batteryShareItem, onDismiss: cleanupBatteryCsvTempFile) { item in
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

            if !record.flightBatterySamples.isEmpty {
                flightBatterySection(record)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
            }
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

    private func cleanupBatteryCsvTempFile() {
        if let url = lastBatteryShareURL {
            ShareImageError.cleanupTempFile(at: url, log: Self.log)
            lastBatteryShareURL = nil
        }
    }

    @ViewBuilder
    private func flightBatterySection(_ record: RaceRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Flight pack (CRSF)")
                .font(.headline)
            ForEach(Array(record.flightBatterySummaryLines().enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("Battery CSV exports raw samples for spreadsheets.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Writes `record.flightBatteryCSVText()` to a temp `.csv` and opens the share sheet.
    private func shareBatteryCsvAction(_ record: RaceRecord) {
        cleanupBatteryCsvTempFile()
        let csv = record.flightBatteryCSVText()
        guard !csv.isEmpty else { return }
        let base = RaceFormat.detailTitle.string(from: record.startedAt)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let name = "HDZap-battery-\(base).csv"
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = dir.appendingPathComponent(name)
        guard let data = csv.data(using: .utf8) else {
            shareError = "Couldn't encode battery CSV as UTF-8."
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            lastBatteryShareURL = url
            batteryShareItem = ShareItem(url: url)
        } catch {
            shareError = "Couldn't write battery CSV (\(error.localizedDescription))."
        }
    }

    private static let log = Logger(subsystem: "sh.saqoo.HDZap", category: "RaceDetailView")
}
