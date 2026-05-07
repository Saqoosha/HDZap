import Foundation
import Observation

/// Per-row horizontal alignment in the goggle OSD. Padding to a fixed
/// 50-char width on the iOS side decides where the text actually lands —
/// firmware just renders whatever the iOS-supplied string contains.
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

struct OSDRowConfig: Equatable, Codable {
    var alignment: OSDRowAlignment
    var visible: Bool

    static let `default` = OSDRowConfig(alignment: .center, visible: true)
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
    /// Rows to shift the 4-row block up from the bottom of the grid.
    /// Range: -13...0 (0 = bottom-anchored default, -13 = block at top).
    /// Lower bound matches the firmware clamp:
    /// `OSDTextDisplay::DEFAULT_BASE_ROW + minYOffset >= 0`. Hardcoded
    /// here rather than computed from OSD_ROWS / ROW_COUNT (which would
    /// require duplicating those constants in iOS) — both ends use 50x18
    /// and a 4-row block, so the bound is stable.
    static let minYOffset = -13
    static let maxYOffset = 0

    /// Rows to shift the 4-row block up from the bottom of the grid.
    var yOffset: Int
    /// Per-row config. Always exactly `OSDLayoutConfig.rowCount` entries;
    /// callers can subscript with the OSD row index 0..3.
    var rows: [OSDRowConfig]

    static let `default` = OSDLayoutConfig(
        yOffset: 0,
        rows: Array(repeating: .default, count: rowCount))

    static func clampYOffset(_ y: Int) -> Int {
        max(minYOffset, min(maxYOffset, y))
    }

    /// Apply per-row alignment + visibility to a single raw row string.
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
                                  alignment: cfg.alignment)
    }
}

/// User-configurable OSD layout. Persisted to UserDefaults; injected as
/// an environment object so SettingsView can edit and TimerView can
/// apply without prop-drilling. Firmware persists nothing — the iOS app
/// replays the y-offset to the M5Stick on connect.
@Observable
@MainActor
final class OSDLayoutSettings {
    static let yOffsetKey = "osdLayout.yOffset"
    static let rowsKey = "osdLayout.rows.v1"

    var yOffset: Int {
        didSet {
            let clamped = OSDLayoutConfig.clampYOffset(yOffset)
            if clamped != yOffset {
                yOffset = clamped
                return
            }
            if oldValue != yOffset {
                UserDefaults.standard.set(yOffset, forKey: Self.yOffsetKey)
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
            }
        }
    }

    init() {
        let savedY = UserDefaults.standard.object(forKey: Self.yOffsetKey) as? Int
        self.yOffset = OSDLayoutConfig.clampYOffset(savedY ?? 0)
        if let data = UserDefaults.standard.data(forKey: Self.rowsKey),
           let decoded = try? JSONDecoder().decode([OSDRowConfig].self, from: data),
           decoded.count == OSDLayoutConfig.rowCount {
            self.rows = decoded
        } else {
            self.rows = Array(repeating: .default, count: OSDLayoutConfig.rowCount)
        }
    }

    var snapshot: OSDLayoutConfig {
        OSDLayoutConfig(yOffset: yOffset, rows: rows)
    }

    func resetToDefaults() {
        yOffset = 0
        rows = Array(repeating: .default, count: OSDLayoutConfig.rowCount)
    }
}
