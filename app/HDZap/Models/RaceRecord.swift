import Foundation

/// Persisted result of a completed race. The on-screen `Lap` type is not
/// `Codable` (it's a runtime view-model), so a parallel `LapEntry` carries
/// just the bytes that round-trip through the JSON file.
///
/// All construction is funneled through `snapshot(...)` (live data) or
/// `init(from:)` (decoded JSON), both of which validate the same
/// invariants: `endedAt >= startedAt`, non-negative session/target,
/// `accentHue` clamped to `0..<360`, and `laps` non-empty. Without that
/// gate, a hand-edited or schema-drifted JSON could load an in-memory
/// record that violates the documented rules and the store would happily
/// write it back out next mutation.
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
    /// Hue in degrees, normalized to `0..<360`. `EditorialTheme.accent(hue:)`
    /// uses the OKLCH hue directly; out-of-range values silently shift to
    /// an unintended colour.
    let accentHue: Double
    let laps: [LapEntry]
    /// CRSF flight-pack battery telemetry captured during the race (may be empty).
    let flightBatterySamples: [RaceFlightBatterySample]

    /// Memberwise init is `private` so every code path has to go through
    /// the validating factory or `init(from:)`. Anything else would let a
    /// caller bypass the invariants and the store can't notice.
    private init(id: UUID,
                 startedAt: Date,
                 endedAt: Date,
                 sessionLimit: TimeInterval,
                 targetLapCount: Int,
                 accentHue: Double,
                 laps: [LapEntry],
                 flightBatterySamples: [RaceFlightBatterySample]) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.sessionLimit = sessionLimit
        self.targetLapCount = targetLapCount
        self.accentHue = accentHue
        self.laps = laps
        self.flightBatterySamples = flightBatterySamples
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(UUID.self, forKey: .id)
        let startedAt = try c.decode(Date.self, forKey: .startedAt)
        let endedAt = try c.decode(Date.self, forKey: .endedAt)
        let sessionLimit = try c.decode(TimeInterval.self, forKey: .sessionLimit)
        let targetLapCount = try c.decode(Int.self, forKey: .targetLapCount)
        let accentHue = try c.decode(Double.self, forKey: .accentHue)
        let laps = try c.decode([LapEntry].self, forKey: .laps)
        let flightBatterySamples = try c.decodeIfPresent([RaceFlightBatterySample].self,
                                                          forKey: .flightBatterySamples) ?? []
        try Self.validate(startedAt: startedAt,
                          endedAt: endedAt,
                          sessionLimit: sessionLimit,
                          targetLapCount: targetLapCount,
                          accentHue: accentHue,
                          laps: laps,
                          flightBatterySamples: flightBatterySamples,
                          coding: c)
        self.init(id: id,
                  startedAt: startedAt,
                  endedAt: endedAt,
                  sessionLimit: sessionLimit,
                  targetLapCount: targetLapCount,
                  accentHue: Self.normalizedHue(accentHue),
                  laps: laps,
                  flightBatterySamples: flightBatterySamples)
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

    /// `Lap` is the runtime view-model type; this re-inflates persisted
    /// `LapEntry` rows so render code can stay generic over both.
    var displayLaps: [Lap] {
        laps.map { Lap(id: $0.id, time: $0.time) }
    }

    /// Snapshot a finished race off the live `LapTimer` state. Returns nil
    /// for empty laps or any other invariant violation — saving a nonsense
    /// record would just clutter the history with something the UI can't
    /// render meaningfully.
    static func snapshot(laps: [Lap],
                         startedAt: Date,
                         endedAt: Date = Date(),
                         sessionLimit: TimeInterval,
                         targetLapCount: Int,
                         accentHue: Double,
                         flightBatterySamples: [RaceFlightBatterySample] = []) -> RaceRecord? {
        let entries = laps.map { LapEntry(id: $0.id, time: $0.time) }
        guard (try? validate(startedAt: startedAt,
                             endedAt: endedAt,
                             sessionLimit: sessionLimit,
                             targetLapCount: targetLapCount,
                             accentHue: accentHue,
                             laps: entries,
                             flightBatterySamples: flightBatterySamples,
                             coding: nil)) != nil else {
            return nil
        }
        return RaceRecord(
            id: UUID(),
            startedAt: startedAt,
            endedAt: endedAt,
            sessionLimit: sessionLimit,
            targetLapCount: targetLapCount,
            accentHue: normalizedHue(accentHue),
            laps: entries,
            flightBatterySamples: flightBatterySamples
        )
    }

    // MARK: - Validation

    /// Single source of truth for the invariants. `coding` is non-nil when
    /// called from `init(from:)`; failures throw `DecodingError` so the
    /// decoder reports the offending key. From `snapshot(...)` the same
    /// failures throw a generic error which the factory turns into `nil`.
    private static func validate(startedAt: Date,
                                 endedAt: Date,
                                 sessionLimit: TimeInterval,
                                 targetLapCount: Int,
                                 accentHue: Double,
                                 laps: [LapEntry],
                                 flightBatterySamples: [RaceFlightBatterySample],
                                 coding: KeyedDecodingContainer<CodingKeys>?) throws {
        if endedAt < startedAt {
            try fail("endedAt < startedAt", key: .endedAt, coding: coding)
        }
        if sessionLimit < 0 || !sessionLimit.isFinite {
            try fail("sessionLimit out of range", key: .sessionLimit, coding: coding)
        }
        if targetLapCount < 0 {
            try fail("targetLapCount negative", key: .targetLapCount, coding: coding)
        }
        if !accentHue.isFinite {
            try fail("accentHue not finite", key: .accentHue, coding: coding)
        }
        if laps.isEmpty {
            try fail("laps empty", key: .laps, coding: coding)
        }
        for lap in laps where !lap.time.isFinite || lap.time < 0 {
            try fail("lap time invalid", key: .laps, coding: coding)
        }
        var seen = Set<Int>()
        for lap in laps {
            // Duplicate ids would break SwiftUI list diffing in `ForEach`.
            if !seen.insert(lap.id).inserted {
                try fail("duplicate lap id", key: .laps, coding: coding)
            }
        }
        var prevTRace: TimeInterval?
        for s in flightBatterySamples {
            if !s.tRace.isFinite {
                try fail("flight battery tRace not finite", key: .flightBatterySamples, coding: coding)
            }
            if s.tRace < -0.25 {
                try fail("flight battery tRace out of range", key: .flightBatterySamples, coding: coding)
            }
            let remBounds = (-2)...102
            if !remBounds.contains(s.remainingPercent) {
                try fail("flight battery remaining pct out of range", key: .flightBatterySamples, coding: coding)
            }
            if let prev = prevTRace, s.tRace + 1e-9 < prev {
                try fail("flight battery samples not chronological", key: .flightBatterySamples, coding: coding)
            }
            prevTRace = s.tRace
        }
    }

    private static func fail(_ reason: String,
                             key: CodingKeys,
                             coding: KeyedDecodingContainer<CodingKeys>?) throws {
        if let coding {
            throw DecodingError.dataCorruptedError(forKey: key,
                                                   in: coding,
                                                   debugDescription: reason)
        }
        throw ValidationError(reason: reason)
    }

    private struct ValidationError: Error { let reason: String }

    /// Wrap any hue input back into `0..<360`. Negatives wrap; values >=
    /// 360 wrap; NaN/inf are filtered earlier so they don't reach here.
    private static func normalizedHue(_ raw: Double) -> Double {
        let m = raw.truncatingRemainder(dividingBy: 360)
        return m < 0 ? m + 360 : m
    }

    private enum CodingKeys: String, CodingKey {
        case id, startedAt, endedAt, sessionLimit, targetLapCount, accentHue, laps
        case flightBatterySamples
    }
}

/// Shared, locale-aware formatters for race timestamps so the row
/// caption and detail nav title stay in sync — split DateFormatters
/// drift the moment one site is tuned and the other isn't.
enum RaceFormat {
    static let rowCaption: DateFormatter = makeFormatter("MMMdHm")
    static let detailTitle: DateFormatter = makeFormatter("MMMdHm")

    private static func makeFormatter(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale.autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }
}
