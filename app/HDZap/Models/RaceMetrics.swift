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
    static func timeLeftRow(remainingSec: TimeInterval) -> String {
        let secs = max(0, Int(remainingSec.rounded()))
        return padOSD("TIME LEFT \(secs)", width: osdRowWidths[0])
    }

    /// Pre-race "Ready" display: race time, target lap count, and target
    /// pace on the goggle so the pilot can verify settings before the start.
    /// No "s" suffix on numbers — the HDZero glyph set renders S as 5.
    static func readyOSDRows(targetLapCount: Int, sessionLimit: TimeInterval) -> [String] {
        let target = clampedTargetLapCount(targetLapCount)
        let pace = targetLapSeconds(for: target, sessionLimit: sessionLimit)
        return [
            padOSD("READY", width: osdRowWidths[0]),
            padOSD("RACE \(Int(sessionLimit))", width: osdRowWidths[1]),
            padOSD("\(target)LAPS @ \(seconds(pace, decimals: 2))", width: osdRowWidths[2]),
            padOSD("", width: osdRowWidths[3]),
        ]
    }

    /// Post-race results: lap count, total time, average, and best lap.
    /// All rows fill the full 50-col grid so labels never truncate.
    /// Row 2 always keeps 1/100s precision — it drops spacing before
    /// dropping a decimal place.
    static func resultOSDRows(lapCount: Int, totalTime: TimeInterval,
                              avgTime: TimeInterval, bestTime: TimeInterval?) -> [String] {
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
        return [
            padOSD("DONE", width: osdRowMaxBytes),
            padOSD("\(lapCount)LAPS \(seconds(totalTime, decimals: 2))", width: osdRowMaxBytes),
            padOSD(row2, width: osdRowMaxBytes),
            padOSD("", width: osdRowMaxBytes),
        ]
    }

    /// Bottom three rows derived from the latest lap, padded so they
    /// can overlay prior content without leftover chars. Sent only
    /// when a lap is recorded — independent of the TIME LEFT tick.
    var osdMetricRows: [String] {
        [
            Self.padOSD("LAP \(lapNumber) \(Self.seconds(lastLapSec, decimals: 3))",
                        width: Self.osdRowWidths[1]),
            Self.padOSD(osdAverageLine, width: Self.osdRowWidths[2]),
            Self.padOSD(osdDiffLine, width: Self.osdRowWidths[3])
        ]
    }

    /// Center text within `width` by adding equal leading and trailing
    /// spaces. Caps at `osdRowMaxBytes` so the BLE payload always fits
    /// the firmware's per-row limit. Unlike right-padding, this produces
    /// a visually centered string on the goggle OSD.
    static func padOSD(_ line: String, width: Int) -> String {
        let cap = min(width, osdRowMaxBytes)
        let text = String(line.prefix(cap))
        let padding = cap - text.count
        if padding <= 0 { return text }
        let left = padding / 2
        let right = padding - left
        return String(repeating: " ", count: left) + text + String(repeating: " ", count: right)
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
