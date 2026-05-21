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
///
/// Marked `@Observable` so SwiftUI's dependency tracker sees `isActive`
/// and `lastError` reads through `RaceCoordinator`'s computed-property
/// forwards. Without this, view redraws on workout-state changes only
/// happen by accident (via the 4 Hz cosmetic tick on `RaceFaceView`),
/// and any code path that drops the tick would silently break the
/// "ARMED" indicator.
@MainActor
@Observable
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
            // Clear a stale lastError so a one-time transient failure
            // doesn't keep the Settings status red after the user has
            // since granted access in the Health app.
            lastError = nil
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
            // Stash references *before* the async beginCollection so a
            // rapid stop() that arrives before the completion can find
            // them and tear down cleanly.
            session = s
            builder = b
            b.beginCollection(withStart: now) { [weak self] ok, err in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let err {
                        log.error("beginCollection failed: \(err.localizedDescription)")
                        self.lastError = err.localizedDescription
                        // Roll back: end the session so HealthKit
                        // doesn't believe we have an active workout.
                        // `isActive` stays false — never claimed it.
                        s.end()
                        self.session = nil
                        self.builder = nil
                        return
                    }
                    if !ok {
                        log.error("beginCollection ok=false with no error — treating as failure")
                        self.lastError = "Workout collection did not start"
                        s.end()
                        self.session = nil
                        self.builder = nil
                        return
                    }
                    // Only flip ARMED once HealthKit confirms collection
                    // is live. Earlier we set this unconditionally before
                    // the callback fired and a beginCollection failure
                    // would leave the UI claiming ARMED while the watch
                    // was actually back in low-power.
                    self.isActive = true
                    // Mirror the auth-success clear: a successful start
                    // means whatever earlier error was surfaced is no
                    // longer relevant.
                    self.lastError = nil
                    log.info("workout collection started")
                }
            }
        } catch {
            log.error("session create failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }

    /// Idempotent — safe to call when no session is running.
    func stop() {
        guard let s = session, let b = builder else { return }
        // Clear state *synchronously* before kicking off the async
        // teardown. A rapid stop()→start() (multi-heat tournament
        // loop) used to hit the `guard session == nil` in start()
        // while the old endCollection completion hadn't yet nilled
        // the field, so the new race lost its keepalive. Local refs
        // (`s`, `b`) keep the async completion working against the
        // outgoing session even though the instance state is now
        // pointing at "no workout".
        session = nil
        builder = nil
        isActive = false
        s.end()
        b.endCollection(withEnd: Date()) { ok, err in
            if let err {
                log.error("endCollection failed: \(err.localizedDescription)")
            }
            // `discardWorkout()` is only valid after a successful end;
            // discarding a builder whose collection didn't end is
            // undefined behavior per Apple's lifecycle docs. On
            // failure we accept that a zero-content workout entry may
            // appear in Health rather than risk a crash.
            if ok {
                b.discardWorkout()
                log.info("workout ended + discarded")
            } else {
                log.warning("workout ended with ok=false — not discarding, may leave a Health entry")
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
        // We don't subscribe any data sources, so this should never fire.
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
        // No-op — we don't insert events.
    }
}
