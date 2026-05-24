import Foundation
import WatchKit
import os

private let log = Logger(subsystem: "sh.saqoo.HDZap.watchkitapp", category: "Haptics")

/// Per-mark haptic. A mark fires one or more `WKHapticType` plays
/// spaced `gap` seconds apart (only used when `repeats > 1`).
///
/// Two hard-won constraints from real-hardware testing on Apple
/// Watch SE 3 informed the choices below:
///
///   1. Same-type chained calls within ~300 ms get coalesced by the
///      haptic engine and only the first one registers. So "tap, tap,
///      tap" with `.notification` × 3 felt like a single tap on the
///      wrist.
///
///   2. The supposedly-distinct built-in types (`.notification`,
///      `.success`, `.retry`, `.click`) all feel like "rapid taps" on
///      this hardware — the user could not reliably tell `.success`
///      from `.retry`. Only `.failure` (a ~1.5 s alarm) felt
///      categorically different.
///
/// So we use *duration* and *repeat count of `.failure`* as the
/// primary discriminators, with two single-tap types (`.notification`,
/// `.directionUp`) for the early marks where the operator can afford
/// to miss a beat.
private struct Mark {
    let remaining: TimeInterval
    let type: WKHapticType
    let repeats: Int
    /// Inter-play gap when `repeats > 1`. Only meaningful for the
    /// 0 s buzzer where we chain two `.failure` calls — same-type
    /// chaining survives coalescing iff the gap exceeds the natural
    /// duration of the type. `.failure` is ~1.5 s long; spacing the
    /// second one at 1.2 s starts it just after the first finishes,
    /// reading as "alarm-alarm" rather than a single longer alarm.
    let gap: TimeInterval
}

/// Schedules and plays the countdown haptic patterns. The watch derives
/// per-mark fire dates from the latest snapshot (no live tick stream
/// required) and arms one `Timer` per *tap*, fired on the main runloop
/// in `.common` mode.
///
/// `arm(_:)` is destructive — it cancels any previously-armed timers
/// and re-computes from scratch. Designed to be called on every
/// snapshot delivery; doing it inline rather than diffing keeps the
/// "session limit changed mid-race" + "race paused / resumed" cases
/// from needing special handling.
///
/// Why `Timer` rather than `Task.sleep(nanoseconds:)`: on real watch
/// hardware (Apple Watch SE 3, watchOS 11) `Task.sleep` drifted 3-5
/// seconds late on the first scheduled mark. `Timer.scheduledTimer(...)`
/// added to the main runloop in `.common` mode fires within ~50 ms of
/// its absolute fire date because the runloop re-evaluates timer
/// deadlines on every iteration.
///
/// Why a single `play()` per mark rather than chained taps: the
/// watch's haptic engine coalesces same-type `play()` calls within
/// ~300 ms, even across separate `Timer`s — count-based discrimination
/// ("1 tap = 30 s, 2 taps = 20 s, 3 taps = 10 s") doesn't survive the
/// coalescing on real hardware. Instead each mark uses a *different*
/// `WKHapticType`, leaning on the system's built-in multi-pulse
/// patterns (`.success`, `.retry`) for the escalation feel.
///
/// Why no Core Haptics: `CoreHaptics` (custom `CHHapticPattern`) is
/// iOS / macOS only. watchOS only exposes the fixed `WKHapticType`
/// set, so the design space is "pick from this menu and accept what
/// the system gives you."
@MainActor
final class HapticScheduler {
    /// Per-mark choreography. Two-tier design: 30 s / 20 s are gentle
    /// single-tap "you're still doing fine" markers, 10 s flips to the
    /// long alarm to signal real urgency, 0 s repeats the alarm so
    /// "race over" is unmistakably distinct from "10 s left." Each
    /// transition (30→20, 20→10, 10→0) is a *qualitative* change in
    /// what the wrist feels, not a subtle escalation that gets lost.
    private static let marks: [Mark] = [
        Mark(remaining: 30, type: .directionUp,  repeats: 1, gap: 0),
        Mark(remaining: 20, type: .notification, repeats: 1, gap: 0),
        Mark(remaining: 10, type: .failure,      repeats: 1, gap: 0),
        Mark(remaining: 0,  type: .failure,      repeats: 2, gap: 1.2),
    ]

    /// All currently-armed timers for the latest snapshot. Cleared
    /// (and individually invalidated) on every `arm(_:)` call so
    /// stale schedules never leak.
    private var timers: [Timer] = []

    /// Recompute the schedule against `snapshot`. Pass nil to disarm.
    func arm(_ snapshot: RaceSnapshot?) {
        timers.forEach { $0.invalidate() }
        timers = []

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

        var scheduled = 0
        for mark in Self.marks {
            let markFireAt = raceStart.addingTimeInterval(snapshot.sessionLimit - mark.remaining)
            if markFireAt < cutoff { continue }

            for repeatIndex in 0..<mark.repeats {
                let tapFireAt = markFireAt.addingTimeInterval(mark.gap * Double(repeatIndex))
                let type = mark.type
                let remaining = mark.remaining
                let repeats = mark.repeats
                let timer = Timer(fire: tapFireAt, interval: 0, repeats: false) { _ in
                    let drift = Date().timeIntervalSince(tapFireAt)
                    log.info("fire mark=\(Int(remaining), privacy: .public)s rep=\(repeatIndex + 1)/\(repeats) type=\(String(describing: type), privacy: .public) drift=\(String(format: "%+.3f", drift), privacy: .public)s")
                    WKInterfaceDevice.current().play(type)
                }
                // .common keeps the timer firing during scroll / digital
                // crown rotation. Strictly not needed here (no scroll on
                // our face) but cheap, and matches the convention used
                // by the iPhone LapTimer's 60Hz tick.
                RunLoop.main.add(timer, forMode: .common)
                timers.append(timer)
                scheduled += 1
            }
        }

        log.info("arm: scheduled \(scheduled) plays across \(Self.marks.count) marks at \(raceStart, privacy: .public)")
    }
}
