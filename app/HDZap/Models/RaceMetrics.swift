import Foundation

struct RaceMetrics: Equatable {
    enum SplitState: Equatable {
        case need
        case bank
        case onTarget
    }

    static let defaultTargetLapCount = 7
    static let minTargetLapCount = 2
    static let maxTargetLapCount = 99
    static let osdRowMaxBytes = 50  // OSD grid width (OSD_COLS)
    static let osdTextRowCount = 4  // matches OSDTextDisplay::ROW_COUNT

    let targetLapCount: Int
    let targetLapSec: TimeInterval
    let lapNumber: Int
    let lapCount: Int
    let lastLapSec: TimeInterval
    let avgLapSec: TimeInterval
    let paceLaps: Int
    let diffSec: TimeInterval
    let remainingLaps: Int
    let perLapSec: TimeInterval

    var splitState: SplitState {
        if abs(diffSec) < 0.005 { return .onTarget }
        return diffSec > 0 ? .need : .bank
    }

    var splitLabel: String {
        switch splitState {
        case .need: return "Need"
        case .bank: return "Bank"
        case .onTarget: return "Split"
        }
    }

    var splitValue: String {
        switch splitState {
        case .need, .bank:
            return "\(Self.signed(perLapSec, decimals: 1))/L"
        case .onTarget:
            return "On"
        }
    }

    var targetDisplay: String {
        "\(targetLapCount)L@\(Self.seconds(targetLapSec, decimals: 2))"
    }

    var avgDisplay: String {
        Self.seconds(avgLapSec, decimals: 3)
    }

    var diffDisplay: String {
        Self.signed(diffSec, decimals: 2)
    }

    var paceDisplay: String {
        "\(paceLaps)L"
    }

    /// Padding width per OSD row. All rows use the same width so every
    /// line is centered at the same column — different widths would put
    /// rows 0-1 at col 18 and rows 2-3 at col 15, making the display
    /// look misaligned. The goggle keeps prior overlay content between
    /// writes (no clear before each row), so a fixed width per row
    /// ensures a shorter update cleanly overwrites a longer prior value.
    static let osdRowWidths: [Int] = [50, 50, 50, 50]  // fill full OSD row

    /// TIME LEFT row, padded so the centered position is stable as the
    /// digit count changes across the full session-limit range (single,
    /// double, and triple digit values; the SettingsView slider goes up
    /// to 180s). The "S" suffix was dropped: on the HDZero glyph set
    /// `S` renders as a `5` and gets read as part of the number
    /// (`45S` → `455`).
    static func timeLeftRow(remainingSec: TimeInterval,
                            layout: OSDLayoutConfig = .default) -> String {
        let secs = max(0, Int(remainingSec.rounded()))
        return layout.renderRow("TIME LEFT \(secs)", at: 0)
    }

    /// Pre-race "Ready" display: race time, target lap count, and target
    /// pace on the goggle so the pilot can verify settings before the start.
    /// No "s" suffix on numbers — the HDZero glyph set renders S as 5.
    static func readyOSDRows(targetLapCount: Int, sessionLimit: TimeInterval,
                             layout: OSDLayoutConfig = .default) -> [String] {
        let target = clampedTargetLapCount(targetLapCount)
        let pace = targetLapSeconds(for: target, sessionLimit: sessionLimit)
        let raws = [
            "READY",
            "RACE \(Int(sessionLimit))",
            "\(target)LAPS @ \(seconds(pace, decimals: 2))",
            "",
        ]
        return raws.enumerated().map { i, raw in layout.renderRow(raw, at: i) }
    }

    /// Post-race results: lap count, total time, average, and best lap.
    /// All rows fill the full 50-col grid so labels never truncate.
    /// Row 2 always keeps 1/100s precision — it drops spacing before
    /// dropping a decimal place.
    static func resultOSDRows(lapCount: Int, totalTime: TimeInterval,
                              avgTime: TimeInterval, bestTime: TimeInterval?,
                              layout: OSDLayoutConfig = .default) -> [String] {
        let best = bestTime.map { seconds($0, decimals: 2) } ?? "--"
        let row2Full = "AVG \(seconds(avgTime, decimals: 2)) BEST \(best)"
        let row2: String
        if row2Full.count <= osdRowMaxBytes {
            row2 = row2Full
        } else {
            let best2 = bestTime.map { seconds($0, decimals: 2) } ?? "--"
            let row2Compact = "AVG\(seconds(avgTime, decimals: 2)) BEST\(best2)"
            if row2Compact.count <= osdRowMaxBytes {
                row2 = row2Compact
            } else {
                let best1 = bestTime.map { seconds($0, decimals: 1) } ?? "--"
                row2 = "AVG\(seconds(avgTime, decimals: 1)) BEST\(best1)"
            }
        }
        let raws = [
            "DONE",
            "\(lapCount)LAPS \(seconds(totalTime, decimals: 2))",
            row2,
            "",
        ]
        return raws.enumerated().map { i, raw in layout.renderRow(raw, at: i) }
    }

    /// Bottom three rows derived from the latest lap, padded so they
    /// can overlay prior content without leftover chars. Sent only
    /// when a lap is recorded — independent of the TIME LEFT tick.
    /// Returned indices map to OSD rows 1, 2, 3 respectively (row 0 is
    /// the TIME LEFT tick), which is also why per-row alignment lookup
    /// adds 1 to the local enumeration index.
    func osdMetricRows(layout: OSDLayoutConfig = .default) -> [String] {
        let raws = [
            "LAP \(lapNumber) \(Self.seconds(lastLapSec, decimals: 3))",
            osdAverageLine,
            osdDiffLine,
        ]
        return raws.enumerated().map { i, raw in layout.renderRow(raw, at: i + 1) }
    }

    /// Pad text within `width` using `alignment` to decide which side
    /// of the string the spaces go on. Caps at `osdRowMaxBytes` so the
    /// BLE payload always fits the firmware's per-row limit.
    /// Center is the legacy default — pre-existing call sites without
    /// an alignment argument keep their original look.
    static func padOSD(_ line: String, width: Int,
                       alignment: OSDRowAlignment = .center) -> String {
        let cap = min(width, osdRowMaxBytes)
        let text = String(line.prefix(cap))
        let padding = cap - text.count
        if padding <= 0 { return text }
        switch alignment {
        case .left:
            return text + String(repeating: " ", count: padding)
        case .right:
            return String(repeating: " ", count: padding) + text
        case .center:
            let left = padding / 2
            let right = padding - left
            return String(repeating: " ", count: left) + text
                + String(repeating: " ", count: right)
        }
    }

    private var osdAverageLine: String {
        let full = "AVG \(Self.seconds(avgLapSec, decimals: 3)) PACE \(paceLaps)L"
        if full.count <= Self.osdRowMaxBytes { return full }

        let compact = "AVG \(Self.seconds(avgLapSec, decimals: 2)) PACE \(paceLaps)L"
        if compact.count <= Self.osdRowMaxBytes { return compact }

        return "AVG \(Self.seconds(avgLapSec, decimals: 2)) P\(paceLaps)L"
    }

    private var osdDiffLine: String {
        let diff = Self.signed(diffSec, decimals: 2)
        switch splitState {
        case .need:
            return compactDiffLine(diff: diff, label: "NEED")
        case .bank:
            return compactDiffLine(diff: diff, label: "BANK")
        case .onTarget:
            return "D\(diff) ON TARGET"
        }
    }

    init?(laps: [Lap],
          targetLapCount rawTargetLapCount: Int,
          sessionLimit: TimeInterval,
          paceOverride: Int? = nil) {
        guard let last = laps.last, !laps.isEmpty else { return nil }
        let target = Self.clampedTargetLapCount(rawTargetLapCount)
        let total = laps.reduce(0) { $0 + $1.time }
        guard total > 0 else { return nil }

        targetLapCount = target
        targetLapSec = Self.targetLapSeconds(for: target, sessionLimit: sessionLimit)
        lapNumber = last.id
        lapCount = laps.count
        lastLapSec = last.time
        avgLapSec = total / Double(laps.count)
        remainingLaps = max(1, target - laps.count)
        diffSec = total - (Double(laps.count) * targetLapSec)
        perLapSec = -diffSec / Double(remainingLaps)

        if let paceOverride {
            paceLaps = paceOverride
        } else {
            let remainingSec = max(0, sessionLimit - total)
            let futureLaps = avgLapSec > 0 ? Int((remainingSec / avgLapSec).rounded(.up)) : 0
            paceLaps = laps.count + futureLaps
        }
    }

    static func clampedTargetLapCount(_ count: Int) -> Int {
        min(maxTargetLapCount, max(minTargetLapCount, count))
    }

    static func targetLapSeconds(for count: Int, sessionLimit: TimeInterval) -> TimeInterval {
        sessionLimit / Double(clampedTargetLapCount(count) - 1)
    }

    static func seconds(_ seconds: TimeInterval, decimals: Int) -> String {
        let format = "%.\(decimals)f"
        return String(format: format, locale: Locale(identifier: "en_US_POSIX"), max(0, seconds))
    }

    static func signed(_ seconds: TimeInterval, decimals: Int) -> String {
        let threshold = 0.5 / pow(10, Double(decimals))
        let clean = abs(seconds) < threshold ? 0 : seconds
        let format = "%+.\(decimals)f"
        return String(format: format, locale: Locale(identifier: "en_US_POSIX"), clean)
    }

    private func compactDiffLine(diff: String, label: String) -> String {
        let perLap = Self.signed(perLapSec, decimals: 1)
        let full = "D\(diff) \(label) \(perLap)/L"
        if full.count <= Self.osdRowMaxBytes { return full }

        let compactDiff = Self.signed(diffSec, decimals: 1)
        let compact = "D\(compactDiff) \(label) \(perLap)/L"
        if compact.count <= Self.osdRowMaxBytes { return compact }

        let coarserPerLap = Self.signed(perLapSec, decimals: 0)
        return "D\(compactDiff) \(label) \(coarserPerLap)/L"
    }
}
