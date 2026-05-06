import SwiftUI

/// Debug subview that ships every ESP-NOW packet the M5Stick sees over
/// BLE for live inspection. Intended for verifying ELRS Backpack
/// telemetry forwarding (LUA → Backpack → Telemetry → ESP-NOW): if the
/// TX backpack is broadcasting, packets from its MAC will appear here
/// once the iOS device is paired with the same UID.
///
/// Mutually exclusive on the firmware side with TX UID Capture — both
/// share the single ESP-NOW recv-callback slot. Starting one preempts
/// the other; this view doesn't render that interaction (the
/// preemption is silent on the firmware side and the iOS state already
/// mirrors it via BluetoothManager.startTelemetryDebug / startTXSniff).
struct BackpackTelemetryDebugView: View {
    @Environment(BluetoothManager.self) private var bluetooth

    /// Wall-clock at the start of the current capture session. Used for
    /// the elapsed-time + packets/sec rate calculation. Reset every
    /// time the user taps Start.
    @State private var sessionStartedAt: Date?
    /// Drives the "packets/sec" recompute. SwiftUI re-evaluates the
    /// header when this ticks; without it the rate would only update on
    /// the next packet arrival, which feels stuck at idle.
    @State private var tickerNow: Date = Date()
    private let ticker = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            statusSection
            controlsSection
            recordsSection
        }
        .navigationTitle("Backpack Telemetry")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(ticker) { now in
            // Only refresh the ticker when a session is active —
            // otherwise we'd repaint the body every second for no
            // reason while the view is just open.
            if bluetooth.isTelemetryDebugActive {
                tickerNow = now
            }
        }
        .onDisappear {
            // Stop the firmware sniffer when the user leaves the view —
            // running in the background would burn ESP-NOW recv-cb work
            // on every backpack packet for no visible benefit, and would
            // also keep the deep-sleep gate armed (telemetry_sniff
            // _active is one of the gates in main.cpp). The user can
            // still re-enter the view to resume.
            if bluetooth.isTelemetryDebugActive {
                _ = bluetooth.stopTelemetryDebug()
            }
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section {
            HStack {
                Circle()
                    .fill(bluetooth.isTelemetryDebugActive ? Color.green : Color.secondary)
                    .frame(width: 10, height: 10)
                Text(bluetooth.isTelemetryDebugActive ? "Capturing" : "Stopped")
                Spacer()
                Text("\(bluetooth.telemetryDebugTotalSeen) pkts")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Rate")
                Spacer()
                Text(rateLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Unique sources")
                Spacer()
                Text("\(uniqueMacCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Status")
        } footer: {
            // Two specific gotchas that surface as "no packets":
            // 1. The TX backpack must be running ELRS 3.4+ with
            //    Backpack → Telemetry → ESP-NOW enabled in the LUA
            //    script. Older / unconfigured TX won't broadcast at all.
            // 2. Both ends must share the same UID (bind phrase) for
            //    the ELRS backpack filter on the M5 to accept the
            //    packets. Pair the M5 with the TX first.
            Text("Requires ELRS Backpack v1.5+ with Backpack → Telemetry → ESP-NOW enabled in the TX LUA script. M5Stick must share the same UID as the TX.")
                .font(.caption2)
        }
    }

    private var controlsSection: some View {
        Section {
            if bluetooth.isTelemetryDebugActive {
                Button("Stop", role: .destructive) {
                    _ = bluetooth.stopTelemetryDebug()
                    sessionStartedAt = nil
                }
            } else {
                Button("Start capture") {
                    if bluetooth.startTelemetryDebug() {
                        sessionStartedAt = Date()
                        tickerNow = Date()
                    }
                }
                .disabled(!bluetooth.isReady)
            }

            Button("Clear log") {
                bluetooth.clearTelemetryDebugLog()
            }
            .disabled(bluetooth.telemetryDebugRecords.isEmpty)
        } header: {
            Text("Controls")
        }
    }

    @ViewBuilder
    private var recordsSection: some View {
        if bluetooth.telemetryDebugRecords.isEmpty {
            Section("Packets") {
                Text(bluetooth.isTelemetryDebugActive
                     ? "Waiting for packets…"
                     : "Tap Start capture to listen for ESP-NOW packets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Section("Packets (newest first)") {
                ForEach(bluetooth.telemetryDebugRecords) { record in
                    recordRow(record)
                }
            }
        }
    }

    private func recordRow(_ record: BackpackTelemetryRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(formatMAC(record.mac))
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(record.payloadLength)B")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text(mspLabel(record))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatHexBytes(record.firstBytes,
                                    actualLength: Int(record.payloadLength)))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Formatting

    private var rateLabel: String {
        guard let started = sessionStartedAt else { return "—" }
        let elapsed = max(tickerNow.timeIntervalSince(started), 0.001)
        // Use the live total, not telemetryDebugRecords.count, so a
        // capacity-trimmed log doesn't make the rate decay artificially.
        let rate = Double(bluetooth.telemetryDebugTotalSeen) / elapsed
        return String(format: "%.1f /s", rate)
    }

    private var uniqueMacCount: Int {
        // Distinct sources in the visible window. A sustained capture
        // shows e.g. "1" (just the bound TX backpack) as the expected
        // healthy case; >1 means another backpack is on-air with the
        // same bind, which the operator probably wants to know.
        Set(bluetooth.telemetryDebugRecords.map { $0.mac }).count
    }

    private func formatMAC(_ mac: [UInt8]) -> String {
        mac.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    private func mspLabel(_ record: BackpackTelemetryRecord) -> String {
        guard let fn = record.mspFunctionCode else {
            return "non-MSP"
        }
        let version = record.isMSPv2 ? "MSPv2" : "MSPv1"
        let name = mspFunctionName(fn) ?? String(format: "0x%04X", fn)
        return "\(version) · \(name)"
    }

    /// Map well-known MSP function codes to human-readable names so the
    /// debug view doesn't read as a wall of hex. Codes match the ones
    /// defined in firmware/include/msp.h plus the common ELRS Backpack
    /// codes used for telemetry forwarding (per the ExpressLRS Backpack
    /// source). Unknown codes fall back to hex at the call site.
    private func mspFunctionName(_ code: UInt16) -> String? {
        switch code {
        case 0x0009: return "ELRS_BIND"
        case 0x00B6: return "SET_OSD_ELEM"
        // ELRS Backpack telemetry forwarding codes — these are the
        // packets we expect to see when the TX has Backpack → Telemetry
        // → ESP-NOW enabled in LUA. Names match the ExpressLRS
        // Backpack repo's MSP definitions.
        case 0x0301: return "BACKPACK_VERSION"
        case 0x0302: return "BACKPACK_SET_RECORDING"
        case 0x0309: return "BACKPACK_CRSF_TLM"
        default: return nil
        }
    }

    private func formatHexBytes(_ bytes: [UInt8], actualLength: Int) -> String {
        // Show only as many bytes as the packet actually contains —
        // padding zeros from the firmware's memset would otherwise lie
        // about packet content for short frames.
        let visible = min(bytes.count, max(actualLength, 0))
        return bytes.prefix(visible)
            .map { String(format: "%02X", $0) }
            .joined(separator: " ")
    }
}
