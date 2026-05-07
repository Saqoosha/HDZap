import SwiftUI

/// User-facing OSD layout editor: global Y offset + per-row alignment +
/// per-row visibility, with a live preview pushed to the goggle.
///
/// Preview push strategy: every meaningful change debounces ~150 ms and
/// then sends the layout char (Y offset only) plus the 4 dummy rows so
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
    /// to fire the layout char (only on Y-offset change) vs. just the
    /// preview rows. Persisting it across pushes also lets us skip a
    /// re-send when the user lands back on the same value.
    @State private var lastPushed: OSDLayoutConfig?
    /// Debounce token. Each settings mutation cancels the prior task and
    /// schedules a fresh 150 ms timer; the in-flight task checks its
    /// own ID before sending so an obsolete one stops cleanly.
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        List {
            yOffsetSection(layout: layout)
            rowSections(layout: layout)
            previewSection
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
        .onChange(of: layout.yOffset) { _, _ in schedulePush() }
        .onChange(of: layout.rows) { _, _ in schedulePush() }
        .onChange(of: bluetooth.isReady) { _, ready in
            // Newly-connected mid-session: replay the layout char + the
            // preview rows so the operator's stored offset takes effect
            // without them having to re-drag the slider.
            if ready { schedulePush(force: true) }
        }
    }

    // MARK: - Sections

    private func yOffsetSection(layout: OSDLayoutSettings) -> some View {
        // Slider exposes Y as a 0…13 "rows up from the bottom" knob —
        // friendlier than asking the user to pick a negative number,
        // and matches how they'll think about it ("move the OSD up 5
        // rows"). Internally still stored as a 0…-13 offset so the
        // wire format matches firmware.
        let upBinding = Binding<Double>(
            get: { Double(-layout.yOffset) },
            set: { layout.yOffset = -Int($0.rounded()) }
        )
        return Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Move up")
                    Spacer()
                    Text("\(-layout.yOffset) rows")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: upBinding,
                    in: Double(-OSDLayoutConfig.maxYOffset)
                        ...Double(-OSDLayoutConfig.minYOffset),
                    step: 1
                )
                Text(rowRangeLabel(layout: layout))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 4)
        } header: {
            Text("Vertical position")
        } footer: {
            Text("Slides the whole 4-row block up from the goggle's bottom edge. 0 keeps the original position.")
                .font(.caption2)
        }
    }

    @ViewBuilder
    private func rowSections(layout: OSDLayoutSettings) -> some View {
        ForEach(0..<OSDLayoutConfig.rowCount, id: \.self) { idx in
            Section("Row \(idx + 1)") {
                rowEditor(idx: idx, layout: layout)
            }
        }
    }

    private func rowEditor(idx: Int, layout: OSDLayoutSettings) -> some View {
        let alignmentBinding = Binding<OSDRowAlignment>(
            get: { layout.rows[idx].alignment },
            set: {
                var rows = layout.rows
                rows[idx].alignment = $0
                layout.rows = rows
            }
        )
        let visibleBinding = Binding<Bool>(
            get: { layout.rows[idx].visible },
            set: {
                var rows = layout.rows
                rows[idx].visible = $0
                layout.rows = rows
            }
        )
        return VStack(alignment: .leading, spacing: 8) {
            Toggle("Show", isOn: visibleBinding)
            Picker("Align", selection: alignmentBinding) {
                ForEach(OSDRowAlignment.allCases) { a in
                    Text(a.displayLabel).tag(a)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!layout.rows[idx].visible)
            previewRowText(idx: idx)
        }
    }

    private var previewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<OSDLayoutConfig.rowCount, id: \.self) { idx in
                    previewRowText(idx: idx)
                }
            }
            .padding(.vertical, 4)
            if !bluetooth.isReady {
                Text("Connect to the M5Stick to preview on the goggle.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if !bluetooth.supportsOSDLayout {
                Text("Connected firmware doesn't support the OSD layout characteristic. Per-row alignment and show/hide still work; vertical position will not.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else {
                Text("Live preview — pushed to the goggle as you adjust.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Preview")
        }
    }

    private func actionsSection(layout: OSDLayoutSettings) -> some View {
        Section {
            Button("Reset layout", role: .destructive) {
                layout.resetToDefaults()
            }
        }
    }

    // MARK: - Preview helpers

    /// Monospaced 50-char preview of a single row, with leading/trailing
    /// spaces visualised by a thin gray rule so the user can see where
    /// the alignment lands within the OSD width.
    private func previewRowText(idx: Int) -> some View {
        let raw = Self.dummyRawRows[idx]
        let rendered = layout.snapshot.renderRow(raw, at: idx)
        return Text(rendered.replacingOccurrences(of: " ", with: "·"))
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(layout.rows[idx].visible ? .primary : .secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowRangeLabel(layout: OSDLayoutSettings) -> String {
        // Firmware base row default is OSD_ROWS - ROW_COUNT = 14. Adding
        // the user's negative offset gives the new top row; +3 gives the
        // bottom row of the 4-row block. Show 1-indexed for readability
        // ("rows 15-18 of 18" sounds more natural than "14-17").
        let top1 = 14 + layout.yOffset + 1
        let bottom1 = top1 + 3
        return "Goggle rows \(top1)-\(bottom1) of 18"
    }

    // MARK: - Push to goggle

    /// Shape preview content like a real in-race frame so the alignment
    /// effect is honest (the user sees proportional digits + a typical
    /// LAP/AVG/DIFF mix, not a single short word that's identical
    /// regardless of alignment).
    /// First row mimics the Running TIME LEFT tick; the lower three
    /// mimic `RaceMetrics.osdMetricRows` for a mid-race lap.
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
        let yChanged = lastPushed?.yOffset != snapshot.yOffset
        let rowsChanged = lastPushed?.rows != snapshot.rows
        if !force && !yChanged && !rowsChanged { return }

        if force || yChanged {
            // Firmware silently no-ops the layout write on older builds
            // that lack the characteristic — `sendOSDLayout` returns
            // false in that case but doesn't surface an error. Per-row
            // alignment + visibility still apply via the OSD text path.
            _ = bluetooth.sendOSDLayout(yOffset: snapshot.yOffset)
        }
        // Always push the rows so alignment / visibility changes (which
        // ride the OSD text path, not the layout char) take effect.
        let rendered: [(row: Int, text: String)] = (0..<OSDLayoutConfig.rowCount).map { idx in
            (row: idx, text: snapshot.renderRow(Self.dummyRawRows[idx], at: idx))
        }
        _ = bluetooth.sendOSDRows(rendered)
        lastPushed = snapshot
    }
}
