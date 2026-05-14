import Foundation
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
        // Receiver references self via the handler; defer
        // construction until after init completes by using an
        // unowned closure capture that resolves to the method.
        receiver = WatchSessionReceiver { [weak self] snapshot in
            self?.handle(snapshot)
        }
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

        // Workout lifecycle gates. Keep the workout alive across
        // pause — in-race STOP is common and we don't want to drop
        // the keepalive between pause and resume.
        switch next.phase {
        case .running, .paused:
            if next.hapticsEnabled {
                workout.start()
            }
        case .idle, .ended:
            workout.stop()
        }

        // Re-arm the scheduler against the latest deadlines.
        scheduler.arm(next)
    }
}
