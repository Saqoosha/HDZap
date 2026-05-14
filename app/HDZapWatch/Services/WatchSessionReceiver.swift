import Foundation
import WatchConnectivity
import os

private let log = Logger(subsystem: "sh.saqoo.HDZap.watchkitapp", category: "Receiver")

/// watchOS-side WCSession activator. Decodes incoming snapshots and
/// forwards the latest to the coordinator on the main actor. The
/// coordinator owns all post-decode side-effects (workout lifecycle,
/// haptic scheduling, UI state) so this layer stays a thin transport.
@MainActor
final class WatchSessionReceiver: NSObject {
    typealias Handler = @MainActor (RaceSnapshot) -> Void

    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
        super.init()
        guard WCSession.isSupported() else {
            // watchOS always returns true here, but the guard keeps
            // the code symmetric with the iOS bridge.
            log.error("WCSession not supported")
            return
        }
        let s = WCSession.default
        s.delegate = self
        s.activate()
    }

    /// On launch, the framework hands us whatever
    /// `applicationContext` was last delivered. Pull it explicitly
    /// after activation so a watch-app launch *after* the iPhone has
    /// already published a `.running` snapshot still sees the race
    /// instead of waiting for the next state change.
    private func ingestReceivedContext() {
        let context = WCSession.default.receivedApplicationContext
        guard !context.isEmpty else { return }
        decodeAndForward(context, source: "receivedApplicationContext")
    }

    private func decodeAndForward(_ context: [String: Any], source: String) {
        do {
            guard let snapshot = try RaceSnapshotWire.decode(context) else {
                log.debug("\(source): no snapshot key in context")
                return
            }
            guard snapshot.schemaVersion == RaceSnapshot.currentSchemaVersion else {
                log.warning("\(source): schema mismatch (\(snapshot.schemaVersion) vs \(RaceSnapshot.currentSchemaVersion)) — dropping")
                return
            }
            handler(snapshot)
        } catch {
            log.error("\(source): decode failed: \(error.localizedDescription)")
        }
    }
}

extension WatchSessionReceiver: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        if let error {
            log.error("activation error: \(error.localizedDescription)")
        } else {
            log.info("activation state=\(activationState.rawValue)")
        }
        Task { @MainActor in
            self.ingestReceivedContext()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            self.decodeAndForward(applicationContext, source: "applicationContext")
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            self.decodeAndForward(message, source: "message")
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        // We don't currently use the reply channel — ack with empty so
        // the iPhone doesn't see a delivery error.
        replyHandler([:])
        Task { @MainActor in
            self.decodeAndForward(message, source: "message+reply")
        }
    }
}
