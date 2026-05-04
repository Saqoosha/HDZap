import Foundation

/// Persisted result of a completed race. The on-screen `Lap` type is not
/// `Codable` (it's a runtime view-model), so a parallel `LapEntry` carries
/// just the bytes we need to round-trip through the JSON file.
struct RaceRecord: Identifiable, Codable, Equatable {
    struct LapEntry: Codable, Equatable {
        let id: Int
        let time: TimeInterval
    }

    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let sessionLimit: TimeInterval
    let targetLapCount: Int
    let accentHue: Double
    let laps: [LapEntry]

    init(id: UUID = UUID(),
         startedAt: Date,
         endedAt: Date,
         sessionLimit: TimeInterval,
         targetLapCount: Int,
         accentHue: Double,
         laps: [LapEntry]) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.sessionLimit = sessionLimit
        self.targetLapCount = targetLapCount
        self.accentHue = accentHue
        self.laps = laps
    }

    var lapCount: Int { laps.count }

    var totalTime: TimeInterval { laps.reduce(0) { $0 + $1.time } }

    var bestLapIndex: Int? {
        guard !laps.isEmpty else { return nil }
        return laps.enumerated().min(by: { $0.element.time < $1.element.time })?.offset
    }

    var bestLapTime: TimeInterval? {
        guard let i = bestLapIndex else { return nil }
        return laps[i].time
    }

    var worstLapTime: TimeInterval? {
        laps.map(\.time).max()
    }

    var avgLapTime: TimeInterval {
        guard !laps.isEmpty else { return 0 }
        return totalTime / Double(laps.count)
    }

    /// Convert back to the runtime `Lap` type used by `RaceShareCard` /
    /// `LapTable`. Kept as a one-liner so callers don't reimplement the
    /// mapping at every render site.
    var displayLaps: [Lap] {
        laps.map { Lap(id: $0.id, time: $0.time) }
    }

    /// Snapshot a finished race off the live `LapTimer` state. Returns nil
    /// when there are no laps to record — saving an empty session would
    /// just clutter the history.
    static func snapshot(laps: [Lap],
                         startedAt: Date,
                         endedAt: Date = Date(),
                         sessionLimit: TimeInterval,
                         targetLapCount: Int,
                         accentHue: Double) -> RaceRecord? {
        guard !laps.isEmpty else { return nil }
        return RaceRecord(
            startedAt: startedAt,
            endedAt: endedAt,
            sessionLimit: sessionLimit,
            targetLapCount: targetLapCount,
            accentHue: accentHue,
            laps: laps.map { LapEntry(id: $0.id, time: $0.time) }
        )
    }
}
