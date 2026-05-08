import SwiftUI

/// User-facing OSD layout editor: preview at the top, then visible-block
/// position slider, single global alignment, per-row show/hide (named by
/// what each row displays), and a Clear OSD button. Adjustments push to
/// the goggle in real time so the pilot can see the new arrangement
/// without running a race.
///
/// Preview push strategy: every meaningful change debounces by
/// `previewDebounceNanos` (80 ms) and then sends the layout char (Y
/// offset only) plus the 4 buffer slots so the pilot sees the new
/// arrangement on the goggle. Debounce avoids flooding ESP-NOW while
/// the user drags the slider — coalesces a drag's intermediate values
/// into one BLE write while staying well under the perceptual lag floor
/// (one BLE connection event + the firmware staging window adds ~40 ms;
/// total perceived lag sits comfortably under 150 ms).
struct OSDLayoutSettingsView: View {
    @Environment(BluetoothManager.self) private var bluetooth
    @Environment(OSDLayoutSettings.self) private var layout
    @Environment(\.dismiss) private var dismiss

    /// Last-pushed snapshot: the dispatcher uses this to decide whether
    /// to fire the layout char (only on Y change) vs. just the buffer
    /// rows. Persisting it across pushes also lets us skip a re-send
    /// when the user lands back on the same value.
    @State private var lastPushed: OSDLayoutConfig?
    /// Debounce token. Each settings mutation cancels the prior task
    /// and schedules a fresh `previewDebounceNanos` timer.
    @State private var debounceTask: Task<Void, Never>?

    /// Slider-drag coalescing window — see struct docstring for the
    /// budget breakdown (BLE connection event + firmware staging adds
    /// another ~40 ms, total perceived lag stays under 150 ms).
    private static let previewDebounceNanos: UInt64 = 80_000_000

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
            // Flag the editor as active so TimerView pauses its own
            // layout-char resync (avoids fighting the editor's debounce
            // for slider drags) and knows to repaint the live race
            // frame on the false transition when the editor pops.
            layout.previewEditorActive = true
            // Push current settings on entry so the goggle shows the
            // dummy preview immediately rather than whatever stale
            // content was last drawn (race results, prior session, ...).
            schedulePush(force: true)
        }
        .onDisappear {
            // Order matters: clear `previewEditorActive` BEFORE
            // cancelling the debounce task. `pushIfChanged` re-checks
            // the flag after its sleep to close the small race where a
            // task already past `Task.isCancelled` lands a dummy-rows
            // write on the goggle after TimerView's flush has repainted
            // the live race frame. If we cancelled first, a Task
            // already in `pushIfChanged` would still see `true` and
            // proceed to write.
            layout.previewEditorActive = false
            debounceTask?.cancel()
            debounceTask = nil
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
    /// up as full-blank slots flanking the visible block (above when
    /// bottom-anchored, below when top-anchored) — that mirrors the
    /// firmware buffer the goggle actually receives.
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
            Button("Send Test OSD") {
                sendTestOSD()
            }
            .disabled(!bluetooth.isReady)
            Button("Clear OSD") {
                _ = bluetooth.sendOSDControl(command: .clear)
            }
            .disabled(!bluetooth.isReady)
            Button("Reset layout", role: .destructive) {
                layout.resetToDefaults()
            }
        } footer: {
            Text("Send Test OSD shows the current iPhone time on the goggle so you can confirm packets are landing. Clear wipes the overlay buffer. Reset layout returns the editor to bottom-anchored, centered, all rows visible.")
                .font(.caption2)
        }
    }

    /// Cached so each Test OSD tap doesn't allocate a fresh
    /// `DateFormatter`. POSIX locale pinned so `yyyy-MM-dd` doesn't
    /// localise into e.g. Japanese-era forms on a JP device — the
    /// goggle's OSD glyph set is 7-bit ASCII.
    private static let testOSDDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let testOSDTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Push the iPhone's current date+time to the goggle so each press
    /// visibly changes — easier to confirm packets are landing than a
    /// fixed string that might already be on screen from a prior press.
    /// Bypasses the editor's debounce/`lastPushed` cache (intentionally:
    /// see `sendOSDRows` call below), so the next real layout change
    /// still re-diffs against `lastPushed` and repaints from scratch —
    /// no spurious "no diff" skip, because the cache still reflects the
    /// dummy preview rows we last sent, not the test content.
    private func sendTestOSD() {
        let now = Date()
        let dateStr = Self.testOSDDateFormatter.string(from: now)
        let timeStr = Self.testOSDTimeFormatter.string(from: now)
        let ms = Int((now.timeIntervalSince1970 * 1000).rounded()) % 1000
        _ = bluetooth.sendOSDRows([
            (row: 0, text: RaceMetrics.padOSD("TEST OSD",
                                             width: RaceMetrics.osdRowWidths[0])),
            (row: 1, text: RaceMetrics.padOSD(dateStr,
                                             width: RaceMetrics.osdRowWidths[1])),
            (row: 2, text: RaceMetrics.padOSD("\(timeStr).\(String(format: "%03d", ms))",
                                             width: RaceMetrics.osdRowWidths[2])),
            // Send row 3 too so a stale DIFF row left over from a
            // previous race doesn't sit underneath the test marker
            // (the firmware no longer clears the goggle overlay
            // between writes).
            (row: 3, text: RaceMetrics.padOSD("",
                                             width: RaceMetrics.osdRowWidths[3])),
        ])
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
    /// actually sees in `RaceMetrics.osdMetricRaws` for a mid-race lap.
    static let dummyRawRows: [String] = [
        "TIME LEFT 45",
        "LAP 3 12.345",
        "AVG 12.345 PACE 7L",
        "D+0.42 NEED -0.10/L",
    ]

    private func schedulePush(force: Bool = false) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            // Debounce window — see `previewDebounceNanos` for budget.
            // The initial onAppear push skips the wait (force == true)
            // so the goggle updates the moment the user opens the
            // screen.
            if !force {
                try? await Task.sleep(nanoseconds: Self.previewDebounceNanos)
                if Task.isCancelled { return }
            }
            // Capture snapshot + isInitial *after* the debounce so the
            // task pushes the latest layout, not whatever was set when
            // schedulePush was called. Matters when a slider drag and
            // a row-toggle land in the same debounce window.
            let snapshot = layout.snapshot
            let isInitial = lastPushed == nil
            await pushIfChanged(snapshot, force: force || isInitial)
        }
    }

    private func pushIfChanged(_ snapshot: OSDLayoutConfig, force: Bool) async {
        // Editor pop sets `previewEditorActive = false` *and* cancels the
        // debounce task, but `Task.isCancelled` is only checked once
        // after the sleep — if the task is already in `pushIfChanged`
        // when cancel fires (small race window between waking and the
        // first BLE write), the dummy preview rows would land on the
        // goggle *after* TimerView's pop-flush has already painted the
        // live race frame. Re-checking the editor flag here closes the
        // window: the editor is the only legitimate caller, so once
        // it's been declared inactive there's nothing this task should
        // be writing.
        guard layout.previewEditorActive else { return }
        guard bluetooth.isReady else { return }
        let yChanged = lastPushed?.firmwareYOffset != snapshot.firmwareYOffset
        let alignChanged = lastPushed?.alignment != snapshot.alignment
        let rowsChanged = lastPushed?.rows != snapshot.rows
        let topChanged = lastPushed?.firstVisibleRow != snapshot.firstVisibleRow
        if !force && !yChanged && !alignChanged && !rowsChanged && !topChanged { return }

        // Track per-write success so `lastPushed` only advances when the
        // goggle actually got the new state. Otherwise a transient BLE
        // failure would suppress the next slider drag at the same value
        // (the change-detection guard above sees "no diff vs lastPushed"
        // and skips), leaving the goggle stuck on stale content.
        var allOK = true
        if force || yChanged {
            // Older firmware that lacks CHR_OSD_LAYOUT silently no-ops
            // the write (sendOSDLayout returns false without surfacing
            // an error so a mixed app/firmware version doesn't spam
            // lastError on every slider tick). Don't treat that as a
            // hard failure for `lastPushed` tracking, since alignment +
            // visibility still apply via the OSD text path; flag only
            // when `supportsOSDLayout` claims the char exists yet the
            // write itself failed.
            let layoutOK = bluetooth.sendOSDLayout(yOffset: snapshot.firmwareYOffset)
            if bluetooth.supportsOSDLayout && !layoutOK { allOK = false }
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
        if !bluetooth.sendOSDRows(rendered) { allOK = false }
        if allOK { lastPushed = snapshot }
    }
}
