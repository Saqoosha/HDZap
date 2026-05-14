import Foundation
import os
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

private let log = Logger(subsystem: "sh.saqoo.HDZap", category: "WatchBridge")

/// iPhone-side WCSession bridge. Owns the singleton activation and
/// the most-recent snapshot, and exposes a small surface for views
/// to read pairing/reachability + push state changes.
///
/// All public mutation runs on `@MainActor`; WCSessionDelegate
/// callbacks (which arrive on a background queue) bounce in via
/// `Task { @MainActor in ... }`. Same convention as
/// `BluetoothManager`.
///
/// We do not depend on `LapTimer` directly — `TimerView` derives a
/// `RaceSnapshot` from its environment and calls `publish(_:)` on
/// every relevant transition. Keeps the bridge ignorant of race
/// semantics so it can stay a thin wire-format/transport layer.
@MainActor
@Observable
final class WatchBridge: NSObject {
    /// Activated session, or nil on devices that don't support WCSession
    /// (e.g. iPad — `isSupported()` returns false). Stored so the
    /// debug HUD and Settings view can render the right empty-state
    /// copy without re-querying the framework.
    private(set) var isSupported: Bool = false
    /// `WCSession.isPaired` — true once a watch is paired with this
    /// iPhone, regardless of whether our companion app is installed.
    private(set) var isPaired: Bool = false
    /// `WCSession.isWatchAppInstalled` — true once the user installs
    /// the HDZap watch app from the Watch app on iPhone.
    private(set) var isWatchAppInstalled: Bool = false
    /// `WCSession.isReachable` — true while the watch app is
    /// foregrounded (or running a workout) AND in BLE/WiFi range.
    /// This is what determines whether `sendMessage` will succeed.
    private(set) var isReachable: Bool = false

    /// The most-recent snapshot we've tried to publish. Held so the
    /// activation completion can flush a pending state if `publish`
    /// was called before `WCSession` finished activating.
    private var lastSnapshot: RaceSnapshot?

    #if canImport(WatchConnectivity)
    private var session: WCSession? {
        guard WCSession.isSupported() else { return nil }
        return WCSession.default
    }
    #endif

    override init() {
        super.init()
        activate()
    }

    func activate() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else {
            log.info("WCSession not supported on this device")
            return
        }
        isSupported = true
        let s = WCSession.default
        s.delegate = self
        s.activate()
        // Cached values are nil/false until activation completes; the
        // delegate callback fills them in on the main actor.
        #endif
    }

    /// Publish the latest race state. Idempotent for unchanged
    /// snapshots — `updateApplicationContext` rejects an exact-equal
    /// dictionary (the framework dedupes), so the encoded JSON's
    /// `publishedAt` field doubles as a nonce that guarantees the
    /// dict differs each call.
    func publish(_ snapshot: RaceSnapshot) {
        lastSnapshot = snapshot
        #if canImport(WatchConnectivity)
        guard let s = session, s.activationState == .activated else {
            log.debug("publish: session not activated, will flush after activation")
            return
        }
        send(snapshot, on: s)
        #endif
    }

    /// One-shot "play this `WKHapticType` on your wrist" command.
    /// Backed by `sendMessage` rather than `updateApplicationContext`
    /// — auditioning a haptic only makes sense when the watch app is
    /// actively reachable (operator is feeling for it), and we don't
    /// want this request persisting into a later race start via the
    /// context channel. Silently no-ops when the watch isn't reachable.
    func sendTestHaptic(typeName: String) {
        #if canImport(WatchConnectivity)
        guard let s = session, s.activationState == .activated, s.isReachable else {
            log.debug("sendTestHaptic: watch not reachable")
            return
        }
        let dict = RaceSnapshotWire.encodeTestHaptic(typeName: typeName)
        s.sendMessage(dict, replyHandler: nil) { error in
            log.debug("sendTestHaptic failed: \(error.localizedDescription)")
        }
        #endif
    }

    #if canImport(WatchConnectivity)
    private func send(_ snapshot: RaceSnapshot, on s: WCSession) {
        let dict: [String: Any]
        do {
            dict = try RaceSnapshotWire.encode(snapshot)
        } catch {
            log.error("publish: encode failed: \(error.localizedDescription)")
            return
        }

        // Always update application context — guaranteed delivery,
        // latest-wins semantics. Survives a backgrounded watch app.
        do {
            try s.updateApplicationContext(dict)
        } catch {
            log.error("updateApplicationContext failed: \(error.localizedDescription)")
        }

        // If the watch app is reachable (foregrounded or in a workout
        // session), also fire a low-latency message so phase
        // transitions land within ~50 ms instead of waiting on the
        // OS's coalescing context-delivery window.
        if s.isReachable {
            s.sendMessage(dict, replyHandler: nil) { error in
                // sendMessage failure is expected when the watch app
                // backgrounds between the reachability check and the
                // send — application context has already been queued
                // above so no recovery action is needed.
                log.debug("sendMessage soft-failed: \(error.localizedDescription)")
            }
        }
    }
    #endif
}

#if canImport(WatchConnectivity)
extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        let reachable = session.isReachable
        Task { @MainActor in
            self.isPaired = paired
            self.isWatchAppInstalled = installed
            self.isReachable = reachable
            if let error {
                log.error("activation error: \(error.localizedDescription)")
            } else {
                log.info("activation state=\(activationState.rawValue) paired=\(paired) installed=\(installed) reachable=\(reachable)")
            }
            // Flush the most-recent snapshot now that the session is live.
            if activationState == .activated, let snapshot = self.lastSnapshot {
                self.send(snapshot, on: session)
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        // iOS-only: triggered when the user pairs a different watch.
        // Activation will follow on its own; nothing to do.
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // iOS-only: re-activate so the new watch (if any) gets state.
        WCSession.default.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        Task { @MainActor in
            self.isPaired = paired
            self.isWatchAppInstalled = installed
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
            // Edge: watch became reachable. Re-send the last snapshot
            // immediately so a freshly-launched watch app doesn't have
            // to wait for the next state change to start its workout
            // session and arm haptics.
            if reachable, let snapshot = self.lastSnapshot {
                self.send(snapshot, on: session)
            }
        }
    }
}
#endif
