import Foundation
import Observation
import WatchConnectivity
import os

/// Receives live heart-rate samples streamed by the HDZapWatch companion
/// app's workout session over WatchConnectivity, and relays race
/// START/STOP so the watch can auto-run its workout alongside the race.
///
/// Mirrors `BluetoothManager`'s flight-battery telemetry surface so
/// `TimerView` can ingest both channels through the same pattern:
/// the latest sample is exposed as `lastHeartRateBpm` +
/// `lastHeartRateReceivedAt` (the pair moves in lockstep), and
/// `heartRateNotifyRevision` increments on every arrival so an
/// `.onChange` observer fires even when consecutive samples carry the
/// same bpm.
///
/// WCSession delegate callbacks arrive on a background queue; every
/// mutation hops to the main actor first. `sendMessage` only reaches the
/// watch while the watch app is frontmost (`isReachable`), which is fine
/// here: the workout session keeps the watch app active for the whole
/// race, and samples that arrive while the phone app is backgrounded are
/// simply dropped by the OS — the race UI is foreground during a race
/// anyway.
@MainActor
@Observable
final class WatchHeartRateManager: NSObject {
    /// Most recent bpm relayed from the watch. `nil` until the first
    /// sample lands after launch.
    private(set) var lastHeartRateBpm: Int?
    /// Wall-clock timestamp of the most recent sample's arrival on the
    /// phone. Moves in lockstep with `lastHeartRateBpm`.
    private(set) var lastHeartRateReceivedAt: Date?
    /// Increments on every sample arrival — the `.onChange` hook, same
    /// role as `BluetoothManager.flightBatteryNotifyRevision`.
    private(set) var heartRateNotifyRevision: UInt32 = 0
    /// True while the watch app is frontmost / workout-active and
    /// messages can be exchanged.
    private(set) var isWatchReachable = false

    private var session: WCSession?

    private static let log = Logger(subsystem: "sh.saqoo.HDZap",
                                    category: "WatchHeartRateManager")

    override init() {
        super.init()
        // Not supported on iPad — `TARGETED_DEVICE_FAMILY` is iPhone-only
        // today, but the guard keeps this safe if that ever changes.
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        session = s
        s.delegate = self
        s.activate()
    }

    /// Best-effort race-state relay: tells the watch to start/stop its
    /// workout session in step with the phone's race. Silently no-ops
    /// when the watch app isn't reachable — heart-rate capture is an
    /// optional garnish on the race, never a blocker, so there's no
    /// error surface beyond a debug log.
    func sendRaceState(running: Bool) {
        guard let s = session, s.activationState == .activated, s.isReachable else { return }
        s.sendMessage(["race": running ? "start" : "stop"], replyHandler: nil) { error in
            Self.log.debug("race-state relay failed: \(error.localizedDescription)")
        }
    }

    private func ingest(bpm: Int) {
        lastHeartRateBpm = bpm
        lastHeartRateReceivedAt = Date()
        heartRateNotifyRevision &+= 1
    }

    private func updateReachability(_ reachable: Bool) {
        isWatchReachable = reachable
    }
}

extension WatchHeartRateManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        if let error {
            Self.log.error("WCSession activation failed: \(error.localizedDescription)")
        }
        let reachable = session.isReachable
        Task { @MainActor in self.updateReachability(reachable) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.updateReachability(reachable) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Watch switch: re-activate so the new paired watch can stream.
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        // Watch sends `["hr": Double, "ts": TimeInterval]` at ~1 Hz while
        // its workout runs. `ts` (watch-side send time) is currently
        // unused — arrival time on the phone is what anchors `tRace`,
        // matching the flight-battery convention.
        guard let bpm = message["hr"] as? Double, bpm.isFinite, bpm > 0 else { return }
        let rounded = Int(bpm.rounded())
        Task { @MainActor in self.ingest(bpm: rounded) }
    }
}
