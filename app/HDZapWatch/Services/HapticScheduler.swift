import Foundation
import WatchKit
import os

private let log = Logger(subsystem: "sh.saqoo.HDZap.watchkitapp", category: "Haptics")

/// Schedules and plays the countdown haptic patterns. The watch derives
/// per-mark fire dates from the latest snapshot (no live tick stream
/// required) and arms one `Task.sleep` per mark.
///
/// `arm(_:)` is destructive — it cancels any previously-armed marks
/// and re-computes from scratch. Designed to be called on every
/// snapshot delivery; doing it inline rather than diffing keeps the
/// "session limit changed mid-race" + "race paused / resumed" cases
/// from needing special handling.
@MainActor
final class HapticScheduler {
    /// Fixed marks for V1. Order intentional — earlier marks first so
    /// the "drop already-passed marks" loop in `arm` short-circuits
    /// correctly when the snapshot lands late.
    static let marks: [(remaining: TimeInterval, pattern: Pattern)] = [
        (30, .single),
        (20, .double),
        (10, .triple),
        (0,  .buzzer),
    ]

    enum Pattern {
        case single
        case double
        case triple
        case buzzer
    }

    /// The single in-flight task that owns all currently-armed sleeps
    /// for the current snapshot. Cancelling it tears down every
    /// pending mark in one call.
    private var pending: Task<Void, Never>?

    /// Recompute the schedule against `snapshot`. Pass nil to disarm.
    func arm(_ snapshot: RaceSnapshot?) {
        pending?.cancel()
        pending = nil

        guard let snapshot else { return }
        guard snapshot.hapticsEnabled else { return }
        guard snapshot.phase == .running else {
            // Buzzer at the moment of `.ended`? No — by the time the
            // operator manually ends, they already know. We only fire
            // the buzzer pattern when `.running` reaches 0 elapsed.
            return
        }

        // Wall-clock anchor: the snapshot's `publishedAt` is the
        // moment the iPhone read its `lapTimer.elapsedTime`. The race
        // started, in iPhone wall-clock terms, at:
        //   raceStart = publishedAt - elapsedAtPublish
        // Each mark fires at:
        //   raceStart + (sessionLimit - mark.remaining)
        let raceStart = snapshot.publishedAt.addingTimeInterval(-snapshot.elapsedAtPublish)

        let now = Date()
        // Allow a 1 s slop — a mark whose deadline passed less than a
        // second ago should still fire. Beyond that, firing late
        // confuses the operator more than skipping does.
        let cutoff = now.addingTimeInterval(-1)

        let armed = Self.marks.compactMap { mark -> (Date, Pattern)? in
            let fireAt = raceStart.addingTimeInterval(snapshot.sessionLimit - mark.remaining)
            return fireAt < cutoff ? nil : (fireAt, mark.pattern)
        }

        guard !armed.isEmpty else {
            log.debug("arm: no marks remain (race already past final buzzer?)")
            return
        }

        log.info("arming \(armed.count) marks")
        pending = Task { [armed] in
            for (fireAt, pattern) in armed {
                let delay = fireAt.timeIntervalSinceNow
                if delay > 0 {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    } catch {
                        return // cancelled
                    }
                }
                if Task.isCancelled { return }
                await Self.play(pattern)
            }
        }
    }

    /// Play one pattern. Inter-tap gap of 180 ms reads as "two
    /// distinct taps" through a sleeve in informal testing. Below
    /// ~120 ms they blend into one buzz; above ~250 ms they read as
    /// "two separate single taps" and the operator counts wrong.
    /// Adjust based on real-device feel before final ship.
    static func play(_ pattern: Pattern) async {
        let device = WKInterfaceDevice.current()
        switch pattern {
        case .single:
            device.play(.notification)
        case .double:
            device.play(.notification)
            try? await Task.sleep(nanoseconds: 180_000_000)
            device.play(.notification)
        case .triple:
            for i in 0..<3 {
                device.play(.notification)
                if i < 2 {
                    try? await Task.sleep(nanoseconds: 180_000_000)
                }
            }
        case .buzzer:
            // .failure is the longest, most attention-grabbing
            // built-in pattern — best fit for "race over."
            device.play(.failure)
        }
    }
}
