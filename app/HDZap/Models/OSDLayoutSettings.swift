import Foundation
import Observation

/// Horizontal alignment for the OSD text block. Padding to a fixed
/// 50-char width on the iOS side decides where the text actually lands —
/// firmware just renders whatever the iOS-supplied string contains.
/// One alignment applies to all 4 rows; per-row alignment was tried and
/// dropped because the lap timer rows always read as a single block, so
/// per-row variation doesn't help the pilot and adds UI without payoff.
enum OSDRowAlignment: Int, CaseIterable, Identifiable, Codable {
    case left = 0
    case center = 1
    case right = 2

    var id: Int { rawValue }

    var displayLabel: String {
        switch self {
        case .left: return String(localized: "Left")
        case .center: return String(localized: "Center")
        case .right: return String(localized: "Right")
        }
    }
}

/// Per-row config. Currently only visibility — alignment moved up to the
/// OSDLayoutConfig root after the per-row variant proved over-engineered.
/// Kept as a struct (rather than a bare `[Bool]`) so future per-row
/// settings can be added without another storage migration.
struct OSDRowConfig: Equatable, Codable {
    var visible: Bool

    static let `default` = OSDRowConfig(visible: true)
}

/// Immutable snapshot used by the OSD render path so layout decisions
/// don't change mid-frame. Pass `OSDLayoutConfig.default` to keep the
/// pre-existing all-centered, all-visible, bottom-anchored behavior.
///
/// Constants live here (not on the @MainActor `OSDLayoutSettings` store)
/// so non-isolated contexts — `RaceMetrics.padOSD`, `OSDLayoutConfig.default`
/// itself — can reference them without crossing actor boundaries.
struct OSDLayoutConfig: Equatable {
    static let rowCount = 4
    /// Total OSD grid height (matches firmware `OSD_ROWS`).
    static let osdGridRows = 18

    /// Top row of the *visible* OSD block, 0-indexed (row 0 = top of
    /// goggle grid, row 17 = bottom). Hidden rows are skipped, so the
    /// visible block's height = `visibleCount`. Range:
    /// `0...maxFirstVisibleRow(visibleCount:)`.
    var firstVisibleRow: Int
    /// Single alignment shared by all 4 rows.
    var alignment: OSDRowAlignment
    /// Per-row config. Always exactly `OSDLayoutConfig.rowCount` entries;
    /// callers can subscript with the OSD row index 0..3.
    var rows: [OSDRowConfig]

    /// Number of rows the user has flagged as visible (0…rowCount).
    var visibleCount: Int {
        rows.lazy.filter(\.visible).count
    }

    /// Top row of the firmware's 4-row buffer on the OSD grid. The
    /// buffer is filled with leading blanks so the visible block lands
    /// at `firstVisibleRow`. Clamped to `[0, osdGridRows - rowCount]` so
    /// the buffer never falls off the grid.
    var bufferTopRow: Int {
        let visCount = max(1, visibleCount)
        let raw = firstVisibleRow + visCount - Self.rowCount
        return max(0, min(Self.osdGridRows - Self.rowCount, raw))
    }

    /// Wire-format Y offset for the firmware's CHR_OSD_LAYOUT char.
    /// Negative = "shift up from default bottom-anchored position"
    /// (DEFAULT_BASE_ROW = `osdGridRows - rowCount` = 14).
    var firmwareYOffset: Int {
        bufferTopRow - (Self.osdGridRows - Self.rowCount)
    }

    /// Last row the visible block occupies on the goggle (1-indexed for
    /// human-readable labels). Returns nil when no rows are visible.
    var visibleBottomRow1Indexed: Int? {
        let vc = visibleCount
        guard vc > 0 else { return nil }
        return firstVisibleRow + vc
    }

    static let `default` = OSDLayoutConfig(
        firstVisibleRow: defaultFirstVisibleRow(visibleCount: rowCount),
        alignment: .center,
        rows: Array(repeating: .default, count: rowCount))

    /// Bottom-anchored default for the given visible count: places the
    /// last visible row at the bottom edge of the goggle grid (row 17).
    /// Falls back to `rowCount`-row anchoring when nothing is visible
    /// so the slider still has a meaningful default.
    static func defaultFirstVisibleRow(visibleCount: Int) -> Int {
        let vc = max(1, min(rowCount, visibleCount))
        return osdGridRows - vc
    }

    /// Maximum slider value: the lowest visible block top row that still
    /// keeps the bottom of the visible block inside the grid.
    static func maxFirstVisibleRow(visibleCount: Int) -> Int {
        defaultFirstVisibleRow(visibleCount: visibleCount)
    }

    static func minFirstVisibleRow(visibleCount _: Int) -> Int { 0 }

    static func clampFirstVisibleRow(_ y: Int, visibleCount: Int) -> Int {
        max(minFirstVisibleRow(visibleCount: visibleCount),
            min(maxFirstVisibleRow(visibleCount: visibleCount), y))
    }

    /// Display label for an OSD row. The 4 rows have stable semantic
    /// roles across race states (Time / Lap / Pace / Diff) — surfaced
    /// here so the visibility editor can label toggles meaningfully
    /// instead of "Row 1", "Row 2".
    static func rowDisplayName(at index: Int) -> String {
        switch index {
        case 0: return String(localized: "Time")
        case 1: return String(localized: "Lap")
        case 2: return String(localized: "Pace")
        case 3: return String(localized: "Diff")
        default: return String(localized: "Row \(index + 1)")
        }
    }

    /// Apply alignment + per-row visibility to a single raw row string.
    /// Hidden rows render as 50 spaces so the goggle's overlay buffer
    /// (which retains prior content between writes) gets cleanly cleared
    /// at that row instead of leaving stale text behind.
    func renderRow(_ raw: String, at index: Int) -> String {
        let cfg = rows.indices.contains(index) ? rows[index] : .default
        if !cfg.visible {
            return String(repeating: " ", count: RaceMetrics.osdRowMaxBytes)
        }
        return RaceMetrics.padOSD(raw,
                                  width: RaceMetrics.osdRowMaxBytes,
                                  alignment: alignment)
    }

    /// Map the firmware buffer's slots (0..rowCount-1) to semantic row
    /// indices. Slots holding a hidden row's blank or padding above /
    /// below the visible block are nil. The visible block always lands
    /// at `firstVisibleRow`; the slot the first visible row occupies
    /// shifts as the user moves the block — bottom-anchored layouts
    /// fill the trailing slots, top-anchored layouts fill the leading
    /// slots. Hidden rows never reserve their own slot — they get folded
    /// into the surrounding blanks (the "skip empty rows" rule).
    func bufferLayout() -> [Int?] {
        var slots: [Int?] = Array(repeating: nil, count: Self.rowCount)
        let visibleSemantics = rows.indices.filter { rows[$0].visible }
        guard !visibleSemantics.isEmpty else { return slots }
        let firstVisSlot = firstVisibleRow - bufferTopRow
        for (offset, semantic) in visibleSemantics.enumerated() {
            let slotIdx = firstVisSlot + offset
            guard slotIdx >= 0, slotIdx < Self.rowCount else { continue }
            slots[slotIdx] = semantic
        }
        return slots
    }

    /// Build the 4-slot firmware buffer for the given semantic rows.
    /// `semanticRaws.count` must equal `rowCount`. Hidden rows are
    /// dropped, visible rows are rendered (alignment + padding), and
    /// the result is padded with 50-space blanks to fill the buffer.
    func renderBuffer(semanticRaws: [String]) -> [String] {
        precondition(semanticRaws.count == Self.rowCount,
                     "renderBuffer expects exactly \(Self.rowCount) raw rows")
        let blank = String(repeating: " ", count: RaceMetrics.osdRowMaxBytes)
        return bufferLayout().map { semanticIdx in
            guard let i = semanticIdx else { return blank }
            return renderRow(semanticRaws[i], at: i)
        }
    }

    /// Buffer slot (0..rowCount-1) currently holding the given semantic
    /// row, or nil if the row is hidden / off-buffer. Used for partial
    /// updates (TIME LEFT tick, lap event) so callers don't have to
    /// build the full buffer when only one or two semantic rows changed.
    func bufferSlot(forSemanticIndex index: Int) -> Int? {
        bufferLayout().firstIndex { $0 == index }
    }
}

/// User-configurable OSD layout. Persisted to UserDefaults; injected as
/// an environment object so SettingsView can edit and TimerView can
/// apply without prop-drilling. Firmware persists nothing — the iOS app
/// replays the y-offset to the M5Stick on connect.
@Observable
@MainActor
final class OSDLayoutSettings {
    /// Storage keys are versioned so the model can evolve without
    /// crashing on stale UserDefaults shapes left over from earlier
    /// builds. v3 reframes the position knob from "top of 4-row block"
    /// to "top of visible block" (visible rows are now packed; hidden
    /// rows don't reserve grid space). v2 values aren't migrated —
    /// both v1 and v2 only ever shipped on a draft / TestFlight beta
    /// branch, and the semantics shifted enough that auto-migrating
    /// would silently move the pilot's OSD position.
    static let firstVisibleRowKey = "osdLayout.firstVisibleRow.v3"
    static let alignmentKey = "osdLayout.alignment.v3"
    static let rowsKey = "osdLayout.rows.v3"

    var firstVisibleRow: Int {
        didSet {
            let clamped = OSDLayoutConfig.clampFirstVisibleRow(firstVisibleRow,
                                                                visibleCount: visibleCount)
            if clamped != firstVisibleRow {
                firstVisibleRow = clamped
                return
            }
            if oldValue != firstVisibleRow {
                UserDefaults.standard.set(firstVisibleRow, forKey: Self.firstVisibleRowKey)
            }
        }
    }

    var alignment: OSDRowAlignment {
        didSet {
            if oldValue != alignment {
                UserDefaults.standard.set(alignment.rawValue, forKey: Self.alignmentKey)
            }
        }
    }

    var rows: [OSDRowConfig] {
        didSet {
            // Defensive: reject any out-of-shape assignment so subscripting
            // OSDLayoutConfig.rows with an OSD row index 0..3 is always safe.
            // Reassigning inside didSet recurses once; the recursion path
            // hits the well-formed branch and the same persistence step.
            if rows.count != OSDLayoutConfig.rowCount {
                let padded = rows + Array(repeating: .default,
                                          count: OSDLayoutConfig.rowCount)
                rows = Array(padded.prefix(OSDLayoutConfig.rowCount))
                return
            }
            if oldValue != rows {
                if let data = try? JSONEncoder().encode(rows) {
                    UserDefaults.standard.set(data, forKey: Self.rowsKey)
                }
                // Visibility change can shrink/grow the slider's max,
                // so re-clamp the stored top after persisting rows.
                let clamped = OSDLayoutConfig.clampFirstVisibleRow(firstVisibleRow,
                                                                    visibleCount: visibleCount)
                if clamped != firstVisibleRow {
                    firstVisibleRow = clamped
                }
            }
        }
    }

    /// Number of visible rows; exposed for views that need to size the
    /// slider's range without rebuilding a full snapshot.
    var visibleCount: Int {
        rows.lazy.filter(\.visible).count
    }

    init() {
        let defaultsRows: [OSDRowConfig]
        if let data = UserDefaults.standard.data(forKey: Self.rowsKey),
           let decoded = try? JSONDecoder().decode([OSDRowConfig].self, from: data),
           decoded.count == OSDLayoutConfig.rowCount {
            defaultsRows = decoded
        } else {
            defaultsRows = Array(repeating: .default, count: OSDLayoutConfig.rowCount)
        }
        self.rows = defaultsRows

        let savedAlign = UserDefaults.standard.object(forKey: Self.alignmentKey) as? Int
        self.alignment = savedAlign.flatMap(OSDRowAlignment.init(rawValue:)) ?? .center

        let visCount = defaultsRows.lazy.filter(\.visible).count
        let savedY = UserDefaults.standard.object(forKey: Self.firstVisibleRowKey) as? Int
        let fallback = OSDLayoutConfig.defaultFirstVisibleRow(visibleCount: visCount)
        self.firstVisibleRow = OSDLayoutConfig.clampFirstVisibleRow(savedY ?? fallback,
                                                                    visibleCount: visCount)
    }

    var snapshot: OSDLayoutConfig {
        OSDLayoutConfig(firstVisibleRow: firstVisibleRow,
                        alignment: alignment,
                        rows: rows)
    }

    func resetToDefaults() {
        rows = Array(repeating: .default, count: OSDLayoutConfig.rowCount)
        alignment = .center
        firstVisibleRow = OSDLayoutConfig.defaultFirstVisibleRow(
            visibleCount: OSDLayoutConfig.rowCount)
    }
}
