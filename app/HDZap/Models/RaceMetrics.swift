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
    static let osdRowMaxBytes = 19

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

    /// Padding width per OSD row. Fixed widths matter because the goggle
    /// keeps prior overlay content between writes (we don't clear before
    /// each row update); a shorter new value would leave stale chars
    /// from the previous frame trailing the centered text. Padding to
    /// a stable width per row pins the centered position so updates
    /// always overwrite the same span.
    static let osdRowWidths: [Int] = [13, 14, 19, 19]

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

    /// Pad to `width` with trailing spaces (or truncate to `width` if
    /// the source is longer). Caps at `osdRowMaxBytes` regardless so
    /// the BLE payload always fits the firmware's per-row limit.
    static func padOSD(_ line: String, width: Int) -> String {
        let cap = min(width, osdRowMaxBytes)
        if line.count >= cap { return String(line.prefix(cap)) }
        return line + String(repeating: " ", count: cap - line.count)
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
