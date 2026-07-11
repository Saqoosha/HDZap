import Foundation
import HealthKit
import Observation
import WatchConnectivity
import os

/// Runs the HealthKit workout session that makes the watch sample heart
/// rate at ~1 Hz, and streams each reading to the phone over
/// WatchConnectivity so `WatchHeartRateManager` (iOS) can stage it for
/// the race recorder.
///
/// Why a workout session at all: outside one, watchOS samples HR only
/// every few minutes and syncs lazily — useless for a 90 s race. An
/// active `HKWorkoutSession` + `HKLiveWorkoutBuilder` is the only
/// supported way to get continuous live HR, and it also keeps this app
/// running with the wrist down for the whole flight.
///
/// The phone relays race START/STOP as `["race": "start"|"stop"]`
/// messages (see `WatchHeartRateManager.sendRaceState`), so once this
/// app is open the workout follows the phone's race automatically; the
/// on-watch button is the manual fallback and the pre-race warm-up path.
///
/// All state mutations run on the main actor; HealthKit and WCSession
/// delegate callbacks arrive on background queues and hop over first.
@MainActor
@Observable
final class WatchWorkoutManager: NSObject {
    /// Latest bpm from the live workout builder; nil until the first
    /// sample after a session starts (HR sensor lock-on takes a few
    /// seconds) and cleared on teardown.
    private(set) var heartRateBpm: Int?
    private(set) var isWorkoutRunning = false
    /// Human-readable last failure for the on-watch footer. Cleared on
    /// a successful start.
    private(set) var lastError: String?

    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    private static let log = Logger(subsystem: "sh.saqoo.HDZap.watchkitapp",
                                    category: "WatchWorkoutManager")

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func toggleWorkout() {
        isWorkoutRunning ? stopWorkout() : startWorkout()
    }

    func startWorkout() {
        guard !isWorkoutRunning, workoutSession == nil else { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            lastError = "Health data unavailable"
            return
        }
        // Share = the workout we save on finish; read = live HR.
        // Requesting on every start is a cheap no-op once granted.
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        let read: Set<HKObjectType> = [HKQuantityType(.heartRate)]
        healthStore.requestAuthorization(toShare: share, read: read) { [weak self] granted, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.lastError = error.localizedDescription
                    return
                }
                guard granted else {
                    self.lastError = "Health access denied"
                    return
                }
                self.beginSession()
            }
        }
    }

    func stopWorkout() {
        // `end()` drives the delegate to `.ended`, which finishes the
        // builder — teardown happens there so the two stop paths (button
        // and phone relay) share one exit.
        workoutSession?.end()
    }

    private func beginSession() {
        guard workoutSession == nil else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = .other
        config.locationType = .outdoor
        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore,
                                                         workoutConfiguration: config)
            session.delegate = self
            builder.delegate = self
            workoutSession = session
            self.builder = builder
            let start = Date()
            session.startActivity(with: start)
            builder.beginCollection(withStart: start) { [weak self] started, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard started else {
                        self.lastError = error?.localizedDescription ?? "Couldn't start collection"
                        self.teardown()
                        return
                    }
                    self.isWorkoutRunning = true
                    self.lastError = nil
                }
            }
        } catch {
            lastError = error.localizedDescription
            teardown()
        }
    }

    /// Called from the session delegate on the `.ended` transition.
    /// Finishing (rather than discarding) saves the flight as a real
    /// workout in the pilot's Activity history — the HR series stays
    /// queryable in Health even if the phone missed messages.
    private func finishCollection() {
        guard let builder else {
            teardown()
            return
        }
        builder.endCollection(withEnd: Date()) { _, _ in
            builder.finishWorkout { _, error in
                if let error {
                    Self.log.error("finishWorkout failed: \(error.localizedDescription)")
                }
                Task { @MainActor [weak self] in self?.teardown() }
            }
        }
    }

    private func teardown() {
        workoutSession = nil
        builder = nil
        isWorkoutRunning = false
        heartRateBpm = nil
    }

    private func publish(bpm: Int) {
        heartRateBpm = bpm
        let session = WCSession.default
        // Reachable == phone app foreground — exactly when a race can be
        // recording. Drops outside that window are fine; this stream is
        // a live feed, not a synced log (Health keeps the full series).
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["hr": Double(bpm), "ts": Date().timeIntervalSince1970],
                            replyHandler: nil) { error in
            Self.log.debug("hr message failed: \(error.localizedDescription)")
        }
    }
}

extension WatchWorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState,
                                    date: Date) {
        guard toState == .ended else { return }
        Task { @MainActor in self.finishCollection() }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.lastError = message
            self.teardown()
        }
    }
}

extension WatchWorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                                    didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let hrType = HKQuantityType(.heartRate)
        guard collectedTypes.contains(hrType),
              let quantity = workoutBuilder.statistics(for: hrType)?.mostRecentQuantity() else { return }
        let bpm = quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        guard bpm.isFinite, bpm > 0 else { return }
        let rounded = Int(bpm.rounded())
        Task { @MainActor in self.publish(bpm: rounded) }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

extension WatchWorkoutManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        if let error {
            Self.log.error("WCSession activation failed: \(error.localizedDescription)")
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let race = message["race"] as? String else { return }
        Task { @MainActor in
            switch race {
            case "start": self.startWorkout()
            case "stop": self.stopWorkout()
            default: break
            }
        }
    }
}
