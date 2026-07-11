import Foundation

/// One Apple Watch heart-rate observation during a saved race.
///
/// Mirrors `RaceFlightBatterySample`'s conventions so persistence, CSV
/// export, and chronological ordering behave identically across both
/// telemetry channels. The watch streams bpm over WatchConnectivity at
/// roughly 1 Hz while its workout session runs; `WatchHeartRateManager`
/// stages the latest value and `TimerView` snapshots it into the race.
struct RaceHeartRateSample: Codable, Equatable {
    /// Seconds elapsed since race `startedAt`; non-negative within valid races.
    let tRace: TimeInterval
    /// Absolute wall-clock `.now` snapshot when the WatchConnectivity
    /// message landed on the phone (watch→phone path latency, ~1 s).
    let receivedAt: Date
    /// Beats per minute as reported by HealthKit's live workout builder,
    /// rounded to the nearest integer on the watch side.
    let bpm: Int

    /// Stable in-race ordering: race time ascending, then receivedAt
    /// ascending on ties. Same comparator shape as the flight-battery
    /// channel so save sites can't desync ordering rules.
    static func chronologicalLess(_ a: RaceHeartRateSample,
                                  _ b: RaceHeartRateSample) -> Bool {
        if a.tRace != b.tRace { return a.tRace < b.tRace }
        return a.receivedAt < b.receivedAt
    }
}

extension Sequence where Element == RaceHeartRateSample {
    /// Convenience for the canonical chronological order used at every
    /// post-race save site.
    func sortedChronologically() -> [RaceHeartRateSample] {
        sorted(by: RaceHeartRateSample.chronologicalLess)
    }
}
