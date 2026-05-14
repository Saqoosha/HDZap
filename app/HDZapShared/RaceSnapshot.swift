import Foundation

/// State the iPhone publishes to the watch. Compiled into both targets
/// (see `project.yml` — `HDZapShared` listed under each target's
/// `sources`) so encoder and decoder can't drift.
///
/// Design: the watch derives the live remaining-time locally from
/// `(elapsedAtPublish, publishedAt, phase)` against `Date()` rather
/// than receiving a 60 Hz tick. This means a single dropped or late
/// snapshot never makes the countdown stutter — the watch already
/// has everything it needs to extrapolate, and a momentary BLE/WCSession
/// outage is invisible to the user.
public struct RaceSnapshot: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case idle      // pre-race, no laps recorded
        case running   // race in progress
        case paused    // operator hit STOP mid-race; clock frozen
        case ended     // race over (manual or buzzer)
    }

    /// Bumped on any breaking shape change. The receiver compares and
    /// silently drops snapshots from a future schema rather than
    /// crashing on a missing key — a forward-rolled iPhone shouldn't
    /// brick the watch during the upgrade window.
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let phase: Phase
    /// Elapsed race time at the moment this snapshot was assembled.
    /// Combined with `publishedAt` and `Date()` on the watch to
    /// extrapolate the live elapsed value when `phase == .running`.
    public let elapsedAtPublish: TimeInterval
    public let publishedAt: Date
    public let sessionLimit: TimeInterval
    public let targetLapCount: Int
    public let lapCount: Int
    /// Mirrored from the iOS `@AppStorage` toggle. The watch obeys
    /// this rather than keeping its own copy — single source of truth
    /// avoids "I disabled it on the phone but the wrist still buzzes."
    public let hapticsEnabled: Bool

    public init(schemaVersion: Int = RaceSnapshot.currentSchemaVersion,
                phase: Phase,
                elapsedAtPublish: TimeInterval,
                publishedAt: Date,
                sessionLimit: TimeInterval,
                targetLapCount: Int,
                lapCount: Int,
                hapticsEnabled: Bool) {
        self.schemaVersion = schemaVersion
        self.phase = phase
        self.elapsedAtPublish = elapsedAtPublish
        self.publishedAt = publishedAt
        self.sessionLimit = sessionLimit
        self.targetLapCount = targetLapCount
        self.lapCount = lapCount
        self.hapticsEnabled = hapticsEnabled
    }

    /// Live elapsed-race-time at `now`, extrapolated from the snapshot.
    /// Only `.running` advances; other phases return the frozen value.
    public func elapsed(at now: Date = Date()) -> TimeInterval {
        switch phase {
        case .running:
            return max(0, elapsedAtPublish + now.timeIntervalSince(publishedAt))
        case .idle, .paused, .ended:
            return elapsedAtPublish
        }
    }

    public func remaining(at now: Date = Date()) -> TimeInterval {
        max(0, sessionLimit - elapsed(at: now))
    }
}

/// Wire-format helpers. WCSession's `applicationContext` is a
/// `[String: Any]` dictionary — we wrap a single Codable JSON blob
/// under one key so the snapshot's shape lives entirely in Swift,
/// not in a hand-curated dictionary that could quietly disagree
/// between sender and receiver.
public enum RaceSnapshotWire {
    /// Single dictionary key carrying the encoded JSON blob.
    public static let key = "snapshot.v1"

    public static func encode(_ snapshot: RaceSnapshot) throws -> [String: Any] {
        let data = try JSONEncoder().encode(snapshot)
        return [key: data]
    }

    /// Returns nil when the dictionary doesn't contain a snapshot
    /// payload (e.g. a stray ping from a future iOS feature) — callers
    /// should treat nil as "ignore," not as an error.
    public static func decode(_ context: [String: Any]) throws -> RaceSnapshot? {
        guard let data = context[key] as? Data else { return nil }
        return try JSONDecoder().decode(RaceSnapshot.self, from: data)
    }
}
