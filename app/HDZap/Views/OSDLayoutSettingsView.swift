import SwiftUI

/// User-facing OSD layout editor: preview at the top, then visible-block
/// position slider, single global alignment, per-row show/hide (named by
/// what each row displays), and a Clear OSD button. Adjustments push to
/// the goggle in real time so the pilot can see the new arrangement
/// without running a race.
///
/// Preview push strategy: every meaningful change debounces ~150 ms and
/// then sends the layout char (Y offset only) plus the 4 buffer slots so
/// the pilot sees the new arrangement on the goggle. Debounce avoids
/// flooding ESP-NOW while the user drags the slider — the firmware's
/// 200 ms render-staging window batches anything that lands inside it
/// into a single ESP-NOW cycle anyway, so a 150 ms debounce gives the
/// staging window a moment to settle before the next push.
struct OSDLayoutSettingsView: View {
    @Environment(BluetoothManager.self) private var bluetooth
    @Environment(OSDLayoutSettings.self) private var layout
    @Environment(\.dismiss) private var dismiss

    /// Last-pushed snapshot: the dispatcher uses this to decide whether
    /// to fire the layout char (only on Y change) vs. just the buffer
    /// rows. Persisting it across pushes also lets us skip a re-send
    /// when the user lands back on the same value.
    @State private var lastPushed: OSDLayoutConfig?
    /// Debounce token. Each settings mutation cancels the prior task and
    /// schedules a fresh 150 ms timer.
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        List {
            previewSection
            positionSection(layout: layout)
            alignmentSection(layout: layout)
            visibilitySection(layout: layout)
            actionsSection(layout: layout)
        }
        .navigationTitle("OSD Layout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear {
            // Push current settings on entry so the goggle shows the
            // dummy preview immediately rather than whatever stale
            // content was last drawn (race results, prior session, ...).
            schedulePush(force: true)
        }
        .onChange(of: layout.firstVisibleRow) { _, _ in schedulePush() }
        .onChange(of: layout.alignment) { _, _ in schedulePush() }
        .onChange(of: layout.rows) { _, _ in schedulePush() }
        .onChange(of: bluetooth.isReady) { _, ready in
            // Newly-connected mid-session: replay the layout char + the
            // preview rows so the operator's stored layout takes effect
            // without them having to re-drag the slider.
            if ready { schedulePush(force: true) }
        }
    }

    // MARK: - Sections

    /// 4-slot monospaced preview shown at the top of the screen so
    /// every adjustment below is judged against the same canvas the
    /// pilot will see on the goggle. Spaces are visualised as `·` so
    /// the alignment effect is obvious at a glance. Hidden rows show
    /// up as full-blank slots above the visible block — that mirrors
    /// the firmware buffer the goggle actually receives.
    private var previewSection: some View {
        let buffer = layout.snapshot.renderBuffer(semanticRaws: Self.dummyRawRows)
        return Section {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<OSDLayoutConfig.rowCount, id: \.self) { slot in
                    previewSlotText(buffer[slot])
                }
            }
            .padding(.vertical, 4)
            statusFootnote
        } header: {
            Text("Preview")
        }
    }

    @ViewBuilder
    private var statusFootnote: some View {
        if !bluetooth.isReady {
            Text("Connect to the M5Stick to preview on the goggle.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if !bluetooth.supportsOSDLayout {
            Text("Connected firmware doesn't support the OSD layout characteristic. Alignment and show/hide still work; vertical position will not.")
                .font(.caption2)
                .foregroundStyle(.orange)
        } else {
            Text("Live preview — pushed to the goggle as you adjust.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func positionSection(layout: OSDLayoutSettings) -> some View {
        // Slider exposes the top row of the *visible* block as a
        // 0-indexed value. Bottom-anchored default = `osdGridRows -
        // visibleCount`. Lower values move the block up. Internally
        // the firmware Y offset is derived in `OSDLayoutConfig`.
        let visCount = layout.visibleCount
        let lo = OSDLayoutConfig.minFirstVisibleRow(visibleCount: visCount)
        let hi = OSDLayoutConfig.maxFirstVisibleRow(visibleCount: visCount)
        let rowBinding = Binding<Double>(
            get: { Double(layout.firstVisibleRow) },
            set: { layout.firstVisibleRow = Int($0.rounded()) }
        )
        let canMove = visCount > 0 && hi > lo
        return Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Top row")
                    Spacer()
                    Text("\(layout.firstVisibleRow + 1)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: rowBinding,
                       in: Double(lo)...Double(max(lo, hi)),
                       step: 1)
                    .disabled(!canMove)
                Text(rowRangeLabel(layout: layout))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 4)
        } header: {
            Text("Position")
        } footer: {
            Text("Top row of the visible OSD block on the goggle (1-indexed). The block is as tall as the number of visible rows; the slider's range adapts so the block never falls off the bottom.")
                .font(.caption2)
        }
    }

    private func alignmentSection(layout: OSDLayoutSettings) -> some View {
        let alignmentBinding = Binding<OSDRowAlignment>(
            get: { layout.alignment },
            set: { layout.alignment = $0 }
        )
        return Section {
            Picker("Alignment", selection: alignmentBinding) {
                ForEach(OSDRowAlignment.allCases) { a in
                    Text(a.displayLabel).tag(a)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Alignment")
        } footer: {
            Text("Applies to all visible rows.")
                .font(.caption2)
        }
    }

    private func visibilitySection(layout: OSDLayoutSettings) -> some View {
        Section {
            ForEach(0..<OSDLayoutConfig.rowCount, id: \.self) { idx in
                let visibleBinding = Binding<Bool>(
                    get: { layout.rows[idx].visible },
                    set: {
                        var rows = layout.rows
                        rows[idx].visible = $0
                        layout.rows = rows
                    }
                )
                Toggle(OSDLayoutConfig.rowDisplayName(at: idx), isOn: visibleBinding)
            }
        } header: {
            Text("Show rows")
        } footer: {
            Text("Hidden rows are skipped on the goggle — visible rows close up the gap so the block stays compact.")
                .font(.caption2)
        }
    }

    private func actionsSection(layout: OSDLayoutSettings) -> some View {
        Section {
            Button("Clear OSD") {
                _ = bluetooth.sendOSDControl(command: .clear)
            }
            .disabled(!bluetooth.isReady)
            Button("Reset layout", role: .destructive) {
                layout.resetToDefaults()
            }
        } footer: {
            Text("Clear wipes the goggle overlay buffer immediately. Reset layout puts the editor back to bottom-anchored, centered, all rows visible — the goggle picks up the new layout on the next render.")
                .font(.caption2)
        }
    }

    // MARK: - Preview helpers

    /// Monospaced 50-char preview of a single buffer slot, with
    /// spaces visualised as `·` so the alignment effect is visible.
    /// Fully-blank slots (all dots) signal a hidden row — they take
    /// grid space but render no glyphs on the goggle.
    private func previewSlotText(_ rendered: String) -> some View {
        let isBlank = rendered.allSatisfy { $0 == " " }
        return Text(rendered.replacingOccurrences(of: " ", with: "·"))
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(isBlank ? Color.secondary.opacity(0.5) : .primary)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowRangeLabel(layout: OSDLayoutSettings) -> String {
        let snap = layout.snapshot
        guard let bottom1 = snap.visibleBottomRow1Indexed else {
            return "All rows hidden — nothing displayed on the goggle."
        }
        let top1 = snap.firstVisibleRow + 1
        if top1 == bottom1 {
            return "Goggle row \(top1) of \(OSDLayoutConfig.osdGridRows)"
        }
        return "Goggle rows \(top1)–\(bottom1) of \(OSDLayoutConfig.osdGridRows)"
    }

    // MARK: - Push to goggle

    /// Shape preview content like a real in-race frame so the alignment
    /// effect is honest (the user sees proportional digits + a typical
    /// LAP/AVG/DIFF mix, not a single short word that's identical
    /// regardless of alignment).
    /// Each row mimics the corresponding semantic content the pilot
    /// actually sees in `RaceMetrics.osdMetricRows` for a mid-race lap.
    static let dummyRawRows: [String] = [
        "TIME LEFT 45",
        "LAP 3 12.345",
        "AVG 12.345 PACE 7L",
        "D+0.42 NEED -0.10/L",
    ]

    private func schedulePush(force: Bool = false) {
        debounceTask?.cancel()
        let snapshot = layout.snapshot
        let isInitial = lastPushed == nil
        debounceTask = Task { @MainActor in
            // 150 ms debounce — enough to coalesce a slider drag's many
            // intermediate values into a single push without feeling laggy.
            // The initial onAppear push skips the wait so the goggle
            // updates the moment the user opens the screen.
            if !force {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if Task.isCancelled { return }
            }
            await pushIfChanged(snapshot, force: force || isInitial)
        }
    }

    private func pushIfChanged(_ snapshot: OSDLayoutConfig, force: Bool) async {
        guard bluetooth.isReady else { return }
        let yChanged = lastPushed?.firmwareYOffset != snapshot.firmwareYOffset
        let alignChanged = lastPushed?.alignment != snapshot.alignment
        let rowsChanged = lastPushed?.rows != snapshot.rows
        let topChanged = lastPushed?.firstVisibleRow != snapshot.firstVisibleRow
        if !force && !yChanged && !alignChanged && !rowsChanged && !topChanged { return }

        if force || yChanged {
            // Firmware silently no-ops the layout write on older builds
            // that lack the characteristic — `sendOSDLayout` returns
            // false in that case but doesn't surface an error. Alignment
            // + visibility still apply via the OSD text path.
            _ = bluetooth.sendOSDLayout(yOffset: snapshot.firmwareYOffset)
        }
        // Always push the full buffer (4 slots) so alignment, visibility,
        // and visible-block position changes (which ride the OSD text
        // path, not the layout char) take effect together. Trailing
        // blanks clear stale text from slots that previously held a
        // visible row but now don't.
        let buffer = snapshot.renderBuffer(semanticRaws: Self.dummyRawRows)
        let rendered: [(row: Int, text: String)] = (0..<OSDLayoutConfig.rowCount).map {
            (row: $0, text: buffer[$0])
        }
        _ = bluetooth.sendOSDRows(rendered)
        lastPushed = snapshot
    }
}
