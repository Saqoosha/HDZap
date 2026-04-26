import SwiftUI
import CoreBluetooth

enum UIDConfigMode: Int, CaseIterable {
    case bindPhrase, manualUID, newPairing
}

/// Captures the proposed UID change so the confirmation alert can
/// describe it precisely. We carry the resolved UID for the modes
/// where it's known up-front (bindPhrase / manualUID); newPairing is
/// only "the M5Stick's hardware MAC" — that value lives on the
/// firmware side, so the alert just warns it'll change.
struct PendingApply: Identifiable {
    let id = UUID()
    let mode: UIDMode
    let resolvedUID: [UInt8]?
}

struct ConnectionView: View {
    @Environment(BluetoothManager.self) private var bluetooth

    @State private var selectedMode: UIDConfigMode = .bindPhrase
    @State private var bindPhrase = ""
    @State private var manualUIDText = ""
    /// Set when the user taps "Apply UID" to defer the actual write
    /// behind a confirmation alert. Tapping Apply by itself shouldn't
    /// silently mutate the M5Stick's current UID — losing a working
    /// bind that way (e.g. selecting "New Pairing" and tapping Apply
    /// without intending to repair anything) is a footgun the user
    /// will not realise has fired until OSD packets stop arriving.
    @State private var pendingApply: PendingApply?
    /// The UID the M5Stick had immediately before the most recent
    /// Apply we sent. Used to offer a one-tap rollback when the new
    /// pairing turns out to be wrong (most commonly: New Pairing
    /// against a goggle whose backpack was flashed with a fixed bind
    /// phrase, where the goggle silently reverts to its compile-time
    /// UID after rebooting and OSD goes dark). Cleared once the user
    /// uses the Restore button.
    @State private var previousUID: [UInt8]?
    /// Drives the auto-test+rollback workflow that runs after every
    /// Apply. Lets the UI show a clear "Pairing… / Verifying… /
    /// Success / Failed (rolled back)" progression instead of
    /// leaving the user to guess whether the new pairing took.
    @State private var pairingPhase: PairingPhase = .idle

    enum PairingPhase: Equatable {
        case idle
        case applying       // BLE write in flight, waiting for it to settle
        case verifying      // Test OSD sent, waiting for delivery callback
        case success        // Goggle ack'd the test packets — pairing works
        case rolledBack     // Test failed; we restored the previous UID
        case failedNoRollback // Test failed and there was no previous UID to restore to
        case timedOut       // Never saw a fresh test result frame
    }

    var body: some View {
        NavigationStack {
            List {
                errorSection
                bleStatusSection
                discoveredDevicesSection
                gogglePairingSection
                pairingStatusSection
                currentUIDSection
                osdTestSection
            }
            .navigationTitle("Connection")
            .alert(applyAlertTitle, isPresented: applyAlertBinding, presenting: pendingApply) { pending in
                Button("Cancel", role: .cancel) { pendingApply = nil }
                Button("Apply", role: .destructive) {
                    let mode = pending.mode
                    pendingApply = nil
                    Task { await runPairingFlow(mode: mode) }
                }
            } message: { pending in
                Text(applyAlertMessage(for: pending))
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var errorSection: some View {
        if let err = bluetooth.lastError {
            let remaining = max(bluetooth.errorLog.count - 1, 0)
            let suppressed = bluetooth.droppedErrorCount
            Section("Error") {
                Text(err).foregroundStyle(.red)
                if remaining > 0 || suppressed > 0 {
                    let suffix = suppressed > 0 ? " (+\(suppressed) suppressed)" : ""
                    Text("\(remaining) more queued\(suffix)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button(remaining > 0 ? "Next" : "Clear") { bluetooth.clearError() }
                    if remaining > 0 || suppressed > 0 {
                        Spacer()
                        Button("Clear all", role: .destructive) {
                            bluetooth.clearAllErrors()
                        }
                    }
                }
            }
        }
    }

    private var bleStatusSection: some View {
        Section("Bluetooth") {
            HStack {
                Text("Status")
                Spacer()
                Circle()
                    .fill(bluetooth.isConnected ? .green : .red)
                    .frame(width: 10, height: 10)
                Text(bluetooth.isConnected ? "Connected" : "Disconnected")
                    .foregroundStyle(.secondary)
            }

            if bluetooth.isConnected, let name = bluetooth.connectedDeviceName {
                HStack {
                    Text("Device")
                    Spacer()
                    Text(name).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button(bluetooth.isScanning ? "Scanning..." : "Scan") {
                    bluetooth.startScan()
                }
                .disabled(bluetooth.isScanning)

                if bluetooth.isConnected {
                    Button("Disconnect", role: .destructive) {
                        bluetooth.disconnect()
                    }
                }
            }
        }
    }

    private var discoveredDevicesSection: some View {
        Section("Discovered Devices") {
            if bluetooth.discoveredDevices.isEmpty {
                Text("No devices found")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(bluetooth.discoveredDevices, id: \.identifier) { peripheral in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(peripheral.name ?? "Unknown")
                                .font(.body)
                            Text(peripheral.identifier.uuidString.prefix(8) + "...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Connect") {
                            bluetooth.connect(peripheral)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var gogglePairingSection: some View {
        Section {
            Picker("Mode", selection: $selectedMode) {
                Text("Bind Phrase").tag(UIDConfigMode.bindPhrase)
                Text("Manual UID").tag(UIDConfigMode.manualUID)
                Text("New Pairing").tag(UIDConfigMode.newPairing)
            }
            .pickerStyle(.segmented)

            switch selectedMode {
            case .bindPhrase:
                TextField("Bind phrase", text: $bindPhrase)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !bindPhrase.isEmpty {
                    let uid = uidFromBindPhrase(bindPhrase)
                    Text("UID: \(formatUID(uid))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            case .manualUID:
                TextField("60:D2:53:8A:B2:00 or 96 210 83 138 178 0", text: $manualUIDText)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                Text("Hex matches the iOS/M5Stick display; decimal matches what HDZero goggles show.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !manualUIDText.isEmpty {
                    switch parseUID(manualUIDText) {
                    case .failure(let err):
                        Text(err.localizedDescription)
                            .font(.caption)
                            .foregroundStyle(.red)
                    case .success(let raw):
                        let normalized = normalizeUID(raw)
                        // Always show the canonical hex form when the user
                        // typed decimal — it confirms the interpretation and
                        // lets them compare against the iOS "Current UID"
                        // section above. When bit0 was set on input, the
                        // normalize step changes it here, which is also the
                        // moment we want to surface to the user.
                        let showParsed = !manualUIDText.contains(":") || normalized != raw
                        if showParsed {
                            let label = (normalized != raw) ? "Normalized" : "Parsed"
                            Text("\(label): \(formatUID(normalized))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            case .newPairing:
                Text("Put your goggle in bind mode (ELRS menu → Bind), then tap Pair below. The M5Stick will switch to a fresh pairing ID and broadcast it to the goggle in one step.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // The bind/manual modes only need to push a UID — Apply
            // covers it. New Pairing is two operations (commit a new
            // UID locally, then broadcast a bind so the goggle picks
            // it up), so it gets its own button that does both back-
            // to-back via BLE writes-with-response so the firmware
            // sees them in order. Splitting this into "Apply UID"
            // and "Send Bind Packet" gave the user too many ways to
            // trip themselves into half-applied state.
            switch selectedMode {
            case .bindPhrase, .manualUID:
                Button("Apply UID") {
                    applyUID()
                }
                .disabled(!canApplyUID)
            case .newPairing:
                Button("Pair with new goggle") {
                    applyUID()
                }
                .disabled(!bluetooth.isConnected)
            }
        } header: {
            Text("Goggle Pairing")
        } footer: {
            // Why this matters: the most common "I tried New Pairing
            // and now nothing works" cause is the goggle's backpack
            // having a hardcoded bind phrase from when it was flashed
            // via ELRS Configurator. In that case the bind packet is
            // accepted at runtime but the goggle silently reverts to
            // the compile-time phrase on its very next reboot. The
            // auto-verify step above will catch this and roll back,
            // but explaining it up-front saves the support ping.
            VStack(alignment: .leading, spacing: 4) {
                Text("If your goggle's backpack was flashed with a fixed bind phrase via ELRS Configurator, that phrase always wins after a reboot — New Pairing won't stick.")
                Text("Use Bind Phrase mode with the same phrase that was flashed, or reflash the backpack with the new phrase.")
            }
            .font(.caption2)
        }
    }

    @ViewBuilder
    private var currentUIDSection: some View {
        if let uid = bluetooth.currentUID {
            Section("Current UID") {
                Text(formatUID(uid))
                    .font(.body.monospaced())
                    .textSelection(.enabled)

                // One-tap rollback: only show when we have a stash
                // AND it differs from the current UID. The latter
                // condition prevents the button from sticking around
                // after the user has already restored (current would
                // then equal previousUID).
                if let prev = previousUID, prev != uid {
                    Button {
                        bluetooth.sendUIDConfig(mode: .manualUID(prev))
                        previousUID = nil
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Restore previous goggle")
                            Text(formatUID(prev))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var osdTestSection: some View {
        Section("Debug") {
            Button("Send Test OSD") {
                bluetooth.sendOSDControl(command: .testOSD)
            }
            .disabled(!bluetooth.isConnected)
            Text("Fires one 'HDZERO TEST' message at the goggle OSD. M5Stick strip shows TEST OK / TEST LOST based on ESP-NOW delivery.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var pairingStatusSection: some View {
        if pairingPhase != .idle {
            Section {
                switch pairingPhase {
                case .idle:
                    EmptyView()
                case .applying:
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Switching pairing… waiting for goggle to settle.")
                    }
                case .verifying:
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Verifying lap times can reach the goggle…")
                    }
                case .success:
                    Label("Pairing works — lap times will appear on this goggle.",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .rolledBack:
                    Label("Goggle didn't accept the new pairing. Restored the previous one.",
                          systemImage: "arrow.uturn.backward.circle.fill")
                        .foregroundStyle(.orange)
                case .failedNoRollback:
                    Label("Goggle didn't accept the new pairing, and there was no previous pairing to fall back to.",
                          systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                case .timedOut:
                    Label("No verification result. The M5Stick may be disconnected — try again, or use Restore previous goggle.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Logic

    private var canApplyUID: Bool {
        guard bluetooth.isConnected else { return false }
        switch selectedMode {
        case .bindPhrase: return !bindPhrase.isEmpty
        case .manualUID:
            if case .success = parseUID(manualUIDText) { return true }
            return false
        case .newPairing: return true
        }
    }

    /// Drive the Apply → wait-to-settle → auto-Test → success / rollback
    /// state machine. The goggle gives no positive ack we can route over
    /// BLE, so we infer "the new pairing works" from a fresh Test OSD
    /// landing successfully (firmware status notify carries the result
    /// back). On failure we automatically restore the previously-known
    /// good UID — that's the recovery path the Restore button exposes
    /// manually, plus a baseline-checking phase to avoid acting on a
    /// stale frame from before this attempt.
    private func runPairingFlow(mode: UIDMode) async {
        // Capture the rollback target up-front — once we send the new
        // UID config the firmware's notify will reflect the new value.
        if let current = bluetooth.currentUID {
            previousUID = current
        }
        pairingPhase = .applying

        bluetooth.sendUIDConfig(mode: mode)
        // Only New Pairing has a goggle-side reboot to wait for; the
        // other modes just need the M5Stick to reinit ESP-NOW.
        let isNewPairing: Bool
        if case .newPairing = mode {
            bluetooth.sendBindCommand()
            isNewPairing = true
        } else {
            isNewPairing = false
        }

        // Settle delay: ESP-NOW reinit on the M5Stick is fast (<100 ms);
        // a goggle reboot after bind takes ~2s (ESP.restart + WiFi
        // re-init). Be generous so we don't false-fail on the bind path.
        let settleNanos: UInt64 = isNewPairing ? 2_500_000_000 : 500_000_000
        try? await Task.sleep(nanoseconds: settleNanos)

        // Snapshot revision BEFORE sending the test, then wait for it
        // to bump. The revision counter advances on every status frame
        // that includes the test_result byte, so we don't accidentally
        // act on a frame that landed for an unrelated reason (lap
        // count change, BLE reconnect status, etc).
        let baselineRev = bluetooth.testResultRevision
        pairingPhase = .verifying
        bluetooth.sendOSDControl(command: .testOSD)

        // Test OSD verify window = 200 ms in firmware + status notify
        // round trip. 2.5s gives comfortable margin even on a slow link.
        let verifyDeadline = Date().addingTimeInterval(2.5)
        while Date() < verifyDeadline && bluetooth.testResultRevision == baselineRev {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        if bluetooth.testResultRevision == baselineRev {
            pairingPhase = .timedOut
            return
        }

        switch bluetooth.lastTestResult {
        case .ok:
            pairingPhase = .success
            // Auto-clear the success badge after a moment — leave the
            // current UID section as the durable "what's set" indicator.
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if pairingPhase == .success { pairingPhase = .idle }
        case .lost, .none:
            if let prev = previousUID {
                bluetooth.sendUIDConfig(mode: .manualUID(prev))
                previousUID = nil
                pairingPhase = .rolledBack
            } else {
                pairingPhase = .failedNoRollback
            }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if pairingPhase == .rolledBack || pairingPhase == .failedNoRollback {
                pairingPhase = .idle
            }
        }
    }

    private func applyUID() {
        let mode: UIDMode
        let resolved: [UInt8]?
        switch selectedMode {
        case .bindPhrase:
            mode = .bindPhrase(bindPhrase)
            resolved = uidFromBindPhrase(bindPhrase)
        case .manualUID:
            guard case .success(let raw) = parseUID(manualUIDText) else { return }
            let normalized = normalizeUID(raw)
            mode = .manualUID(normalized)
            resolved = normalized
        case .newPairing:
            mode = .newPairing
            resolved = nil
        }
        // Stage the change behind the confirmation alert. The actual
        // BLE write only happens when the user taps Apply in the alert.
        pendingApply = PendingApply(mode: mode, resolvedUID: resolved)
    }

    private var applyAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingApply != nil },
            set: { if !$0 { pendingApply = nil } }
        )
    }

    private var applyAlertTitle: String {
        switch pendingApply?.mode {
        case .newPairing: return "Pair with a new goggle?"
        default: return "Change goggle pairing?"
        }
    }

    private func applyAlertMessage(for pending: PendingApply) -> String {
        // Wording is deliberately outcome-first ("lap times will/won't
        // appear") rather than mechanism-first ("UID / ESP-NOW / bind
        // phrase"). The user we're protecting from a footgun mostly
        // doesn't care about the IDs themselves — they care that the
        // goggle stops showing lap times. The hex IDs are still shown
        // as a postscript so a power user can verify what's happening.
        let from = bluetooth.currentUID.map(formatUID) ?? "unknown"
        switch pending.mode {
        case .bindPhrase, .manualUID:
            let to = pending.resolvedUID.map(formatUID) ?? "unknown"
            return """
            Lap times will stop appearing on your current goggle and start going to a new one.

            Make sure your goggle is set up to receive from the new pairing — otherwise nothing will show up.

            From: \(from)
            To:   \(to)
            """
        case .newPairing:
            return """
            This switches the M5Stick to a fresh pairing ID and broadcasts it to your goggle in one step.

            Make sure your goggle is in bind mode (ELRS menu → Bind) BEFORE tapping Apply, otherwise the goggle won't pick up the new pairing.

            If your goggle's backpack was flashed with a fixed bind phrase, the goggle will silently revert to that on its next reboot — use Restore previous goggle to get lap times back.

            Current pairing: \(from)
            """
        }
    }
}
