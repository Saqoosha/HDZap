import SwiftUI

private enum UIDConfigMode: CaseIterable {
    case bindPhrase, manualUID, newPairing
}

/// Captures the proposed UID change so the confirmation alert can
/// describe it precisely. `resolvedUID` is derived from `mode`, so the
/// alert message can render the exact UID for `bindPhrase`/`manualUID`
/// (computing it again here would duplicate the parser logic) and
/// returns nil for `newPairing` (the firmware decides).
private struct PendingApply: Identifiable {
    let id = UUID()
    let mode: UIDMode

    /// Computed from `mode` so the alert message and the underlying
    /// transport state can never disagree — there's no separate field
    /// to keep in sync.
    var resolvedUID: [UInt8]? {
        switch mode {
        case .bindPhrase(let phrase): return uidFromBindPhrase(phrase)
        case .manualUID(let uid): return uid
        case .newPairing: return nil
        }
    }
}

/// Goggle pairing sub-screen: current UID + restore-previous + the
/// bind-phrase / manual-UID / new-pairing configurator + TX UID sniff.
/// All three sections share a single confirmation alert + auto-test
/// rollback flow, so they live together rather than being split across
/// the settings root.
struct PairingSettingsView: View {
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
    // The "restore previous goggle" rollback target lives on
    // `BluetoothManager.previousUID` so it survives the sheet being
    // dismissed and reopened — see BluetoothManager docstring.
    /// Drives the auto-test+rollback workflow that runs after every
    /// Apply. Lets the UI show a clear "Pairing… / Verifying… /
    /// Success / Failed (rolled back)" progression instead of
    /// leaving the user to guess whether the new pairing took.
    @State private var pairingPhase: PairingPhase = .idle
    /// Held so we can cancel the in-flight pairing flow if the user
    /// pops the navigation stack mid-flow (no orphaned BLE writes
    /// against a deallocated view), or starts a second Apply before
    /// the success/failure badge auto-clears (one in-flight at a time).
    @State private var pairingTask: Task<Void, Never>?

    enum PairingPhase: Equatable {
        case idle
        case applying       // BLE write in flight, waiting for it to settle
        case verifying      // Test OSD sent, waiting for delivery callback
        case success        // Goggle ack'd the test packets — pairing works
        case rolledBack     // Test failed; we restored the previous UID
        case failedNoRollback // Test failed and there was no previous UID to restore to
        case verifyFailedSameUID // Test failed but pairing was a same-UID re-apply — nothing changed
        case timedOut       // Never saw a fresh test result frame
        case bindBroadcastFailed // newPairing: UID committed locally, bind packet didn't go out
        case restoring      // Restore-previous-goggle button: BLE write in flight
        case restoreFailed  // Restore-previous-goggle BLE write bounced
    }

    var body: some View {
        List {
            currentUIDSection
            pairingSection
            txSniffSection
        }
        .navigationTitle("Pairing")
        .navigationBarTitleDisplayMode(.inline)
        .alert(applyAlertTitle, isPresented: applyAlertBinding, presenting: pendingApply) { pending in
            Button("Cancel", role: .cancel) { pendingApply = nil }
            Button("Apply", role: .destructive) {
                let mode = pending.mode
                pendingApply = nil
                // Cancel any prior in-flight flow first — covers the
                // double-tap window between a success/failure badge
                // showing and its auto-clear sleep finishing.
                pairingTask?.cancel()
                pairingTask = Task { await runPairingFlow(mode: mode) }
            }
        } message: { pending in
            Text(applyAlertMessage(for: pending))
        }
        .onDisappear {
            // User popped the navigation stack mid-flow. Cancel any
            // in-flight task so its remaining BLE writes (rollback
            // sendUIDConfig, success-path Clear OSD) don't fire against
            // a torn-down view's `@State`. The user reaches the same
            // recovery path via the Restore button on re-entry.
            pairingTask?.cancel()
            pairingTask = nil
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var currentUIDSection: some View {
        if let uid = bluetooth.currentUID {
            Section("Current UID") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatUIDDecimal(uid))
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    Text(formatUID(uid))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                // One-tap rollback: only show when we have a stash
                // AND it differs from the current UID. The latter
                // condition prevents the button from sticking around
                // after the user has already restored.
                if let prev = bluetooth.previousUID, prev != uid {
                    Button {
                        // Drive `pairingPhase` so a BLE-write failure
                        // surfaces visibly here on the sub-screen — the
                        // root error banner isn't visible from this
                        // drilldown, so a silent no-op would leave the
                        // user re-tapping with no feedback.
                        pairingPhase = .restoring
                        if bluetooth.sendUIDConfig(mode: .manualUID(prev)) {
                            bluetooth.recordPreviousUID(nil)
                            pairingPhase = .idle
                        } else {
                            pairingPhase = .restoreFailed
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Restore previous goggle")
                            Text(formatUIDDecimal(prev))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(formatUID(prev))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary.opacity(0.7))
                        }
                    }
                }
            }
        }
    }

    private var pairingSection: some View {
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
                TextField("96,210,83,138,178,0 or 60:D2:53:8A:B2:00", text: $manualUIDText)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                Text("Decimal matches what HDZero goggles and the M5Stick LCD show; hex matches MAC tools.")
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
                            // Two distinct keys ("Normalized: %@" / "Parsed: %@")
                            // rather than "%@: %@" so each label translates
                            // independently — the labels are not always
                            // equivalent across languages.
                            let parsedKey: LocalizedStringKey = (normalized != raw)
                                ? "Normalized: \(formatUID(normalized))"
                                : "Parsed: \(formatUID(normalized))"
                            Text(parsedKey)
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
                .disabled(!bluetooth.isReady)
            }

            // In-section status banner — shown only while a pairing flow is active.
            if pairingPhase != .idle {
                pairingStatusContent
            }
        } header: {
            Text("Configure")
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

    private var txSniffSection: some View {
        Section {
            txSniffContent
        } header: {
            Text("TX UID Capture")
        } footer: {
            Text("Press Bind on the TX to broadcast its UID. The TX's existing goggle binding is unaffected.")
                .font(.caption2)
        }
    }

    @ViewBuilder
    private var txSniffContent: some View {
        if bluetooth.isTXSniffActive {
            HStack(spacing: 8) {
                ProgressView()
                Text("Waiting for TX bind packet…")
                    .foregroundStyle(.secondary)
            }
            Button("Stop", role: .destructive) {
                _ = bluetooth.stopTXSniff()
            }
        } else {
            Button("Start TX UID Capture") {
                bluetooth.clearCapturedTXUID()
                _ = bluetooth.startTXSniff()
            }
            .disabled(!bluetooth.isConnected)
        }

        if let uid = bluetooth.capturedTXUID {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Captured TX UID")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formatUIDDecimal(uid))
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    Text(formatUID(uid))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Apply") {
                    // Stop the sniff first so a stray Bind packet during
                    // the alert doesn't overwrite `capturedTXUID`. The
                    // Apply itself routes through the same pendingApply
                    // alert as Manual UID — without it the operator can
                    // accidentally change pairings with a single tap and
                    // not realise lap times stopped reaching the goggle.
                    _ = bluetooth.stopTXSniff()
                    pendingApply = PendingApply(mode: .manualUID(uid))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!bluetooth.isReady)
            }
        }
    }

    @ViewBuilder
    private var pairingStatusContent: some View {
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
        case .verifyFailedSameUID:
            Label("Goggle didn't ack the verify packet, but the pairing on the M5Stick is unchanged — try again, or move closer to the goggle.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .timedOut:
            let restoreVisible = bluetooth.currentUID != nil
                && bluetooth.previousUID != nil
                && bluetooth.previousUID != bluetooth.currentUID
            // Whole-sentence keys (rather than splicing in a localized
            // suffix) so the trailing hint can be rephrased in context —
            // suffix concatenation traps translators into a fixed order.
            let timeoutKey: LocalizedStringKey = restoreVisible
                ? "No verification result. The M5Stick may be disconnected — try again, or use Restore previous goggle."
                : "No verification result. The M5Stick may be disconnected — try again."
            Label(timeoutKey,
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .bindBroadcastFailed:
            // newPairing path: the UID write to the M5Stick succeeded
            // (so the local pairing changed) but the bind broadcast
            // didn't go out. The goggle never heard about the new UID,
            // so lap times silently stop landing. Tell the user the
            // recovery path explicitly: tap Restore.
            Label("Couldn't broadcast the bind packet. The M5Stick switched to a fresh pairing but your goggle wasn't notified — use Restore previous goggle.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .restoring:
            HStack(spacing: 8) {
                ProgressView()
                Text("Restoring previous pairing…")
            }
        case .restoreFailed:
            Label("Couldn't restore the previous pairing — the M5Stick may have disconnected. Try again.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Logic

    private var canApplyUID: Bool {
        guard bluetooth.isReady else { return false }
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
    ///
    /// `@MainActor` is explicit (not just inherited from the View) so
    /// the compiler rejects future call sites that try to invoke this
    /// from `Task.detached` or another non-main async helper —
    /// `BluetoothManager.recordError` runtime-asserts main-actor
    /// isolation, so a silent isolation drift would crash at runtime
    /// rather than fail at build time.
    @MainActor
    private func runPairingFlow(mode: UIDMode) async {
        // Capture the rollback target up-front — once we send the new
        // UID config the firmware's notify will reflect the new value.
        // Pass the optional through directly so a `nil` `currentUID`
        // (status notify hasn't landed yet) clears any stale stash from
        // a prior session instead of silently leaving it pointing at the
        // wrong M5Stick.
        bluetooth.recordPreviousUID(bluetooth.currentUID)
        pairingPhase = .applying

        // Bail before the settle delay if the actual BLE write didn't go
        // out — otherwise we'd run the verify step against the goggle's
        // unchanged UID and falsely report "Pairing works". Drop the
        // stash too: it equals `currentUID` (no displacement happened),
        // so the Restore button would be hidden, and the `.timedOut`
        // copy that says "use Restore previous goggle" would lie.
        guard bluetooth.sendUIDConfig(mode: mode) else {
            bluetooth.recordPreviousUID(nil)
            pairingPhase = .timedOut
            return
        }
        // Only New Pairing has a goggle-side reboot to wait for; the
        // other modes just need the M5Stick to reinit ESP-NOW.
        let isNewPairing: Bool
        if case .newPairing = mode {
            guard bluetooth.sendBindCommand() else {
                // UID write landed but the bind broadcast didn't go out
                // — the M5Stick has switched to a fresh pairing UID
                // that the goggle never heard about, so lap times will
                // silently stop reaching it. Show the dedicated
                // `.bindBroadcastFailed` copy that points at Restore
                // (the actionable recovery), not `.timedOut` ("M5Stick
                // disconnected") which would send the user looking for
                // a phantom BLE issue. `previousUID` stays valid as the
                // rollback target — keep it for the user.
                pairingPhase = .bindBroadcastFailed
                return
            }
            isNewPairing = true
        } else {
            isNewPairing = false
        }

        // Settle delay: ESP-NOW reinit on the M5Stick is fast (<100 ms);
        // a goggle reboot after bind takes ~2s (ESP.restart + WiFi
        // re-init). Be generous so we don't false-fail on the bind path.
        let settleNanos: UInt64 = isNewPairing ? 2_500_000_000 : 500_000_000
        try? await Task.sleep(nanoseconds: settleNanos)
        if Task.isCancelled { return }

        // Snapshot revision BEFORE sending the test, then wait for it
        // to bump. The revision counter advances on every status frame
        // that carries a real test result; clearing `lastTestResult`
        // first means a stale `.ok` from a prior verify can't be read
        // out of the loop on an unrelated status frame's revision bump.
        let baselineRev = bluetooth.testResultRevision
        bluetooth.clearTestResult()
        pairingPhase = .verifying
        // If even the verify probe can't go out, the loop below will spin
        // out the whole 2.5s waiting for a notify that will never arrive.
        // Skip straight to the timeout state so the user sees actionable
        // copy ("M5Stick may be disconnected") immediately.
        guard bluetooth.sendOSDControl(command: .testOSD) else {
            pairingPhase = .timedOut
            return
        }

        // Test OSD verify window = 200 ms in firmware + status notify
        // round trip. 2.5s gives comfortable margin even on a slow link.
        // Loop until the revision bumps AND a real test result has
        // landed (`lastTestResult != .none`) — guards against an
        // unrelated status frame ending the loop with a stale value.
        let verifyDeadline = Date().addingTimeInterval(2.5)
        while Date() < verifyDeadline {
            if bluetooth.testResultRevision != baselineRev
                && bluetooth.lastTestResult != .none {
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return }
        }

        if bluetooth.lastTestResult == .none {
            pairingPhase = .timedOut
            return
        }

        switch bluetooth.lastTestResult {
        case .ok:
            pairingPhase = .success
            // Verify probe leaves "HDZERO TEST" at row 0 col 0 of the
            // goggle OSD; clear it now so the operator doesn't have to
            // hunt for the Clear OSD button after every successful pair.
            // Fire-and-forget — failure surfaces via lastError but isn't
            // worth blocking the success UX on.
            _ = bluetooth.sendOSDControl(command: .clear)
            // Auto-clear the success badge after a moment — leave the
            // current UID section as the durable "what's set" indicator.
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if Task.isCancelled { return }
            if pairingPhase == .success { pairingPhase = .idle }
        case .lost, .none:
            // Skip the rollback when there's no *different* UID to revert
            // to. Re-applying the current UID would be a no-op write and
            // the "Restored the previous one." copy would lie about a
            // change that never happened — most often this fires when the
            // operator re-applies the same bind phrase and the verify
            // false-fails on a transient RF dip. The dedicated
            // `.verifyFailedSameUID` phase tells the user that truthfully.
            if let prev = bluetooth.previousUID, prev != bluetooth.currentUID {
                // Only consume the rollback target when the BLE write is
                // accepted; if it bounces (BLE drop, characteristic gone),
                // keep the stash so the user can retry via the manual
                // Restore button once the link recovers.
                if bluetooth.sendUIDConfig(mode: .manualUID(prev)) {
                    bluetooth.recordPreviousUID(nil)
                    pairingPhase = .rolledBack
                } else {
                    pairingPhase = .timedOut
                }
            } else if bluetooth.previousUID != nil {
                // We had a stash but it equals currentUID — this was a
                // same-UID re-apply, not a fresh pairing that lost a
                // baseline. Tell the user truthfully.
                pairingPhase = .verifyFailedSameUID
            } else {
                pairingPhase = .failedNoRollback
            }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if Task.isCancelled { return }
            switch pairingPhase {
            case .rolledBack, .failedNoRollback, .verifyFailedSameUID:
                pairingPhase = .idle
            default: break
            }
        }
    }

    private func applyUID() {
        let mode: UIDMode
        switch selectedMode {
        case .bindPhrase:
            mode = .bindPhrase(bindPhrase)
        case .manualUID:
            guard case .success(let raw) = parseUID(manualUIDText) else { return }
            mode = .manualUID(normalizeUID(raw))
        case .newPairing:
            mode = .newPairing
        }
        // Stage the change behind the confirmation alert. The actual
        // BLE write only happens when the user taps Apply in the alert.
        // `PendingApply.resolvedUID` is computed from `mode`, so the
        // alert message can render the exact UID without us threading
        // a parallel field that could fall out of sync.
        pendingApply = PendingApply(mode: mode)
    }

    private var applyAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingApply != nil },
            set: { if !$0 { pendingApply = nil } }
        )
    }

    private var applyAlertTitle: String {
        switch pendingApply?.mode {
        case .newPairing: return String(localized: "Pair with a new goggle?")
        default: return String(localized: "Change goggle pairing?")
        }
    }

    private func applyAlertMessage(for pending: PendingApply) -> String {
        // Wording is deliberately outcome-first ("lap times will/won't
        // appear") rather than mechanism-first ("UID / ESP-NOW / bind
        // phrase"). The user we're protecting from a footgun mostly
        // doesn't care about the IDs themselves — they care that the
        // goggle stops showing lap times. The hex IDs are still shown
        // as a postscript so a power user can verify what's happening.
        let from = bluetooth.currentUID.map(formatUID) ?? String(localized: "unknown")
        switch pending.mode {
        case .bindPhrase, .manualUID:
            let to = pending.resolvedUID.map(formatUID) ?? String(localized: "unknown")
            return String(localized: """
            Lap times will stop appearing on your current goggle and start going to a new one.

            Make sure your goggle is set up to receive from the new pairing — otherwise nothing will show up.

            From: \(from)
            To:   \(to)
            """)
        case .newPairing:
            return String(localized: """
            This switches the M5Stick to a fresh pairing ID and broadcasts it to your goggle in one step.

            Make sure your goggle is in bind mode (ELRS menu → Bind) BEFORE tapping Apply, otherwise the goggle won't pick up the new pairing.

            If your goggle's backpack was flashed with a fixed bind phrase, the goggle will silently revert to that on its next reboot — use Restore previous goggle to get lap times back.

            Current pairing: \(from)
            """)
        }
    }
}
