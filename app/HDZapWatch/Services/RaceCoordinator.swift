import Foundation
import WatchKit
import os

private let log = Logger(subsystem: "sh.saqoo.HDZap.watchkitapp", category: "Coordinator")

/// Single owner of all the watch-side moving pieces: the WCSession
/// receiver, the workout keepalive, and the haptic scheduler. The
/// view binds to `snapshot` and reads `phase` / `remaining(at:)` for
/// display; everything below the surface is internal to this class.
@MainActor
@Observable
final class RaceCoordinator {
    private(set) var snapshot: RaceSnapshot?
    /// Read by the view to render a small "WORKOUT" pip — useful for
    /// the first user to confirm the keepalive actually started.
    var isWorkoutActive: Bool { workout.isActive }
    /// Surfaced for the view's empty state — if HealthKit auth was
    /// denied the operator should know.
    var workoutError: String? { workout.lastError }

    private let workout = WorkoutKeepalive()
    private let scheduler = HapticScheduler()
    private var receiver: WatchSessionReceiver?

    init() {
        receiver = WatchSessionReceiver(
            onSnapshot: { [weak self] snapshot in
                self?.handle(snapshot)
            },
            onTestHaptic: { [weak self] typeName in
                self?.playTestHaptic(typeName: typeName)
            }
        )
    }

    /// Eager HealthKit prompt — called from the view's first appear so
    /// the dialog is out of the way before a race actually starts.
    /// Safe to call repeatedly; HealthKit deduplicates.
    func primeAuthorizationIfNeeded() {
        Task { await workout.requestAuthorization() }
    }

    private func handle(_ next: RaceSnapshot) {
        // Drop snapshots older than the one we already have — out-of-
        // order delivery on application context is rare but possible
        // when an app launch ingests `receivedApplicationContext`
        // mid-message-delivery.
        if let prev = snapshot, next.publishedAt < prev.publishedAt {
            log.debug("dropping stale snapshot")
            return
        }
        log.info("snapshot phase=\(next.phase.rawValue) elapsed=\(next.elapsedAtPublish) limit=\(next.sessionLimit) haptics=\(next.hapticsEnabled)")
        snapshot = next

        // Workout lifecycle: hold the keepalive whenever the operator
        // has haptics turned on and the race isn't done yet — pre-race
        // `.idle` and mid-race `.paused` included. The earlier "start
        // on `.running`" gate left the watch in regular foreground
        // mode during the pre-race window, so the WCSession message
        // carrying the `.running` transition could land tens of
        // seconds late (the watch had entered its low-power state) and
        // the first haptic mark fired several seconds behind. Starting
        // the workout now — the moment the operator toggles haptics
        // on in iPhone Settings — makes the watch a real-time WCSession
        // participant before the race begins.
        if next.hapticsEnabled && next.phase != .ended {
            workout.start()
        } else {
            workout.stop()
        }

        // Re-arm the scheduler against the latest deadlines.
        scheduler.arm(next)
    }

    /// Play a single `WKHapticType` by name. Used by the iPhone
    /// Settings "Try haptics" UI so the operator can audition each
    /// built-in type on their wrist. The string-name encoding lets
    /// the iPhone target stay free of any `WatchKit` import — only
    /// the watch knows the enum cases.
    private func playTestHaptic(typeName: String) {
        guard let type = Self.hapticType(named: typeName) else {
            log.warning("test haptic: unknown type \(typeName)")
            return
        }
        WKInterfaceDevice.current().play(type)
    }

    /// String → `WKHapticType`. The set must match the labels the
    /// iPhone Settings UI sends — adding a case here without
    /// surfacing it in Settings is fine (just unused), but the
    /// reverse silently drops the test request.
    private static func hapticType(named name: String) -> WKHapticType? {
        switch name {
        case "notification":   return .notification
        case "click":          return .click
        case "success":        return .success
        case "failure":        return .failure
        case "retry":          return .retry
        case "start":          return .start
        case "stop":           return .stop
        case "directionUp":    return .directionUp
        case "directionDown":  return .directionDown
        default:               return nil
        }
    }
}
