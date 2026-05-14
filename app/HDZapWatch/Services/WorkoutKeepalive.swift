import Foundation
import HealthKit
import os

private let log = Logger(subsystem: "sh.saqoo.HDZap.watchkitapp", category: "Workout")

/// Owns an `HKWorkoutSession` for the duration of a race so the watch
/// app stays runnable in the background and `WKInterfaceDevice.play(...)`
/// fires reliably even with the wrist down or screen off.
///
/// We don't collect health samples — the workout is purely a runtime
/// keepalive. `discardWorkout()` on stop keeps the user's Health log
/// clean of zero-content entries.
@MainActor
final class WorkoutKeepalive: NSObject {
    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    private(set) var isActive = false
    private(set) var lastError: String?

    /// Request authorization for the workout type we'll write. Safe to
    /// call repeatedly — HealthKit deduplicates and only prompts the
    /// user the first time. We deliberately don't request heart rate,
    /// distance, or any other sample types: the auth prompt copy stays
    /// minimal and matches the honest reason we use HealthKit at all.
    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            log.error("Health data unavailable on this device")
            return
        }
        do {
            try await store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [])
        } catch {
            log.error("auth failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }

    /// Idempotent — safe to call when a session is already running.
    func start() {
        guard session == nil else { return }
        guard HKHealthStore.isHealthDataAvailable() else { return }

        let cfg = HKWorkoutConfiguration()
        // `.other` matches the actual activity (race timekeeping, not
        // a recognized fitness modality) without overstating it.
        // `.indoor` suppresses GPS — we don't want it and the user
        // shouldn't be asked for location auth.
        cfg.activityType = .other
        cfg.locationType = .indoor

        do {
            let s = try HKWorkoutSession(healthStore: store, configuration: cfg)
            let b = s.associatedWorkoutBuilder()
            b.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: cfg)
            s.delegate = self
            b.delegate = self

            let now = Date()
            s.startActivity(with: now)
            b.beginCollection(withStart: now) { ok, err in
                if let err {
                    log.error("beginCollection failed: \(err.localizedDescription)")
                }
                _ = ok
            }

            session = s
            builder = b
            isActive = true
            log.info("workout started")
        } catch {
            log.error("session create failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }

    /// Idempotent — safe to call when no session is running.
    func stop() {
        guard let s = session else { return }
        s.end()
        // discardWorkout() removes the (empty) workout from Health so
        // the user doesn't see a litter of 0-calorie entries every
        // race. End the collection first; discard after.
        builder?.endCollection(withEnd: Date()) { [weak self] _, _ in
            self?.builder?.discardWorkout()
            Task { @MainActor [weak self] in
                self?.session = nil
                self?.builder = nil
                self?.isActive = false
                log.info("workout ended + discarded")
            }
        }
    }
}

extension WorkoutKeepalive: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState,
                                    date: Date) {
        log.info("workout state \(fromState.rawValue) -> \(toState.rawValue)")
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        log.error("workout failed: \(error.localizedDescription)")
        Task { @MainActor in
            self.lastError = error.localizedDescription
            self.isActive = false
            self.session = nil
            self.builder = nil
        }
    }
}

extension WorkoutKeepalive: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                                    didCollectDataOf collectedTypes: Set<HKSampleType>) {
        // We don't subscribe any data sources, so this should never
        // fire. Left empty rather than fatalError'd in case Apple
        // adds default collectors in a future watchOS release.
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
        // No-op — we don't insert events.
    }
}
