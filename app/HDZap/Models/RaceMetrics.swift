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
    /// Race window in seconds. Bounds matched to typical FPV race
    /// formats: 60 s = a single fast hot-lap heat, 180 s = a long
    /// endurance round. Step 5 s keeps the slider readable without
    /// forcing a stepper for every increment.
    static let defaultSessionLimit = 90
    static let minSessionLimit = 60
    static let maxSessionLimit = 180
    static let sessionLimitStep = 5
    /// `@AppStorage` keys. Centralized so every binding site
    /// (HDZapApp's `register(defaults:)` block, TimerView, and the
    /// Settings root) points at the same string — a typo on one side
    /// would silently fork the saved value into a parallel key.
    static let targetLapCountStorageKey = "targetLapCount"
    static let raceSessionLimitStorageKey = "raceSessionLimit"
    static let osdRowMaxBytes = 50  // OSD grid width (OSD_COLS)

    let targetLapCount: Int
    let targetLapSec: TimeInterval
    let lapNumber: Int
    let lapCount: Int
    let lastLapSec: TimeInterval
    let avgLapSec: TimeInterval
    let paceLaps: Int
    let diffSec: TimeInterval
    /// Target laps still to run: zero or negative once the pilot has
    /// completed the target lap count. The voice path takes this raw;
    /// display goes through `hasRemainingTargetLaps`.
    let remainingTargetLaps: Int
    let perLapSec: TimeInterval

    /// Whether a per-remaining-lap figure still means anything — **the one
    /// place this rule is written down**; other sites point here.
    ///
    /// `perLapSec` divides by `max(1, remainingTargetLaps)`, so the divisor
    /// stops shrinking at the target lap count while the numerator keeps
    /// growing. Past that point `perLapSec` is the whole accumulated diff:
    /// same magnitude as the Diff column, opposite sign (`perLapSec` is
    /// negated so Need reads negative), dressed up as a per-lap rate.
    var hasRemainingTargetLaps: Bool { remainingTargetLaps > 0 }

    var splitState: SplitState {
        if abs(diffSec) < 0.005 { return .onTarget }
        return diffSec > 0 ? .need : .bank
    }

    var splitLabel: String {
        // Neutral heading once there's no per-lap figure to head — "NEED"
        // over a blank cell reads like a missing value rather than a
        // retired one. Direction is still on screen: the Diff column keeps
        // the signed total, highlighted.
        guard hasRemainingTargetLaps else { return "Split" }
        switch splitState {
        case .need: return "Need"
        case .bank: return "Bank"
        case .onTarget: return "Split"
        }
    }

    var splitValue: String {
        switch splitState {
        case .need, .bank:
            // See `hasRemainingTargetLaps`. Em dash matches the placeholder
            // the views already use when there are no metrics at all.
            guard hasRemainingTargetLaps else { return "—" }
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

    /// TIME LEFT row, raw form (no padding/alignment — `OSDLayoutConfig`
    /// applies those when rendering the buffer). The "S" suffix was
    /// dropped: on the HDZero glyph set `S` renders as a `5` and gets
    /// read as part of the number (`45S` → `455`).
    static func timeLeftRaw(remainingSec: TimeInterval) -> String {
        let secs = max(0, Int(remainingSec.rounded()))
        return "TIME LEFT \(secs)"
    }

    /// Pre-race "Ready" display: 4 raw semantic rows. The 4th is empty
    /// because there's no useful split/diff line before any laps exist.
    /// No "s" suffix on numbers — the HDZero glyph set renders S as 5.
    static func readyOSDRaws(targetLapCount: Int,
                             sessionLimit: TimeInterval) -> [String] {
        let target = clampedTargetLapCount(targetLapCount)
        let pace = targetLapSeconds(for: target, sessionLimit: sessionLimit)
        return [
            "READY",
            "RACE \(Int(sessionLimit))",
            "\(target)LAPS @ \(seconds(pace, decimals: 2))",
            "",
        ]
    }

    /// Post-race results: 4 raw semantic rows (DONE / lap count + total /
    /// AVG + BEST / blank). Row 2 always keeps 1/100s precision — it
    /// drops spacing before dropping a decimal place so the line still
    /// fits the full 50-col grid even with long values.
    static func resultOSDRaws(lapCount: Int, totalTime: TimeInterval,
                              avgTime: TimeInterval,
                              bestTime: TimeInterval?) -> [String] {
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
            "DONE",
            "\(lapCount)LAPS \(seconds(totalTime, decimals: 2))",
            row2,
            "",
        ]
    }

    /// Bottom three semantic rows derived from the latest lap (LAP /
    /// AVG+PACE / DIFF). Returned indices map to OSD semantic rows
    /// 1, 2, 3 — TIME LEFT (semantic 0) is updated independently on the
    /// 1 Hz tick.
    func osdMetricRaws() -> [String] {
        [
            "LAP \(lapNumber) \(Self.seconds(lastLapSec, decimals: 3))",
            osdAverageLine,
            osdDiffLine,
        ]
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
        remainingTargetLaps = target - laps.count
        diffSec = total - (Double(laps.count) * targetLapSec)
        // Local, not a stored property: clamping keeps `perLapSec` finite,
        // but a `remainingLaps` anyone could read is a footgun — it answers
        // "how many laps left?" with 1 forever past the target. Ask
        // `hasRemainingTargetLaps` instead.
        let divisor = max(1, remainingTargetLaps)
        perLapSec = -diffSec / Double(divisor)

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
        // See `hasRemainingTargetLaps` — let the `D…` total speak alone.
        guard hasRemainingTargetLaps else { return "D\(diff) \(label)" }
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

#if DEBUG
/// Pins the per-lap-share behaviour on both sides of the target lap count —
/// the rule itself lives on `RaceMetrics.hasRemainingTargetLaps`.
///
/// No unit-test target exists in this project, so this runs once at launch
/// from `HDZapApp.init()` alongside `_oklchSanityCheck()`. Deliberately not
/// in `RaceMetrics.init` — that runs on every lap of every race.
func _raceMetricsRemainingLapsSanityCheck() {
    // 7 laps in 90 s → 6 flying intervals → targetLapSec 15.0.
    func metrics(lapCount: Int, lapTime: TimeInterval) -> RaceMetrics? {
        RaceMetrics(laps: (1...lapCount).map { Lap(id: $0, time: lapTime) },
                    targetLapCount: 7,
                    sessionLimit: 90)
    }

    // Mid-race: 3 laps at 17 s = 6 s behind, spread over the 4 laps left.
    guard let mid = metrics(lapCount: 3, lapTime: 17) else {
        assertionFailure("mid-race RaceMetrics failed to build")
        return
    }
    assert(mid.remainingTargetLaps == 4 && mid.hasRemainingTargetLaps,
           "expected 4 remaining target laps, got \(mid.remainingTargetLaps)")
    assert(mid.splitState == .need, "3×17 s against a 15 s target should read Need")
    assert(mid.splitValue == "-1.5/L", "expected -1.5/L, got \(mid.splitValue)")
    assert(mid.splitLabel == "Need", "expected the Need heading, got \(mid.splitLabel)")

    // Final target lap: one lap left, so the clamp is a no-op and the rate
    // must still be shown. The case that catches a guard mis-widened to > 1.
    guard let last = metrics(lapCount: 6, lapTime: 17) else {
        assertionFailure("final-target-lap RaceMetrics failed to build")
        return
    }
    assert(last.remainingTargetLaps == 1 && last.hasRemainingTargetLaps,
           "expected 1 remaining target lap, got \(last.remainingTargetLaps)")
    assert(last.splitValue == "-12.0/L", "expected -12.0/L, got \(last.splitValue)")

    // Target reached: 7 laps at 13 s. `diffSec` is -14 s, so `perLapSec` is
    // its whole magnitude with the sign flipped (+14) — a per-lap rate in
    // name only.
    guard let done = metrics(lapCount: 7, lapTime: 13) else {
        assertionFailure("target-reached RaceMetrics failed to build")
        return
    }
    assert(!done.hasRemainingTargetLaps,
           "expected no remaining target laps, got \(done.remainingTargetLaps)")
    assert(done.splitState == .bank, "7×13 s against a 15 s target should read Bank")
    assert(done.splitValue == "—", "expected an em dash, got \(done.splitValue)")
    assert(done.splitLabel == "Split",
           "heading should go neutral once the rate retires, got \(done.splitLabel)")
    // Pin the DIFF row itself rather than "contains no /L" — an absent
    // substring also passes on an empty or malformed row, and the PACE row
    // (`7L`) is one format change away from matching a loose search.
    assert(done.osdMetricRaws()[2] == "D-14.00 BANK",
           "expected the DIFF row to drop the rate, got \(done.osdMetricRaws()[2])")
    assert(done.diffDisplay == "-14.00", "expected -14.00, got \(done.diffDisplay)")

    // Past the target: still flying after the target lap count, which is the
    // normal end of a fast pilot's race rather than an edge case.
    guard let past = metrics(lapCount: 9, lapTime: 13) else {
        assertionFailure("past-target RaceMetrics failed to build")
        return
    }
    assert(past.remainingTargetLaps == -2 && !past.hasRemainingTargetLaps,
           "expected -2 remaining target laps, got \(past.remainingTargetLaps)")
    assert(past.splitValue == "—", "expected an em dash, got \(past.splitValue)")
}
#endif
