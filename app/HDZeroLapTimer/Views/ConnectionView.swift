import SwiftUI
import CoreBluetooth

enum UIDConfigMode: Int, CaseIterable {
    case bindPhrase, manualUID, newPairing
}

struct ConnectionView: View {
    @Environment(BluetoothManager.self) private var bluetooth

    @State private var selectedMode: UIDConfigMode = .bindPhrase
    @State private var bindPhrase = ""
    @State private var manualUIDText = ""

    var body: some View {
        NavigationStack {
            List {
                errorSection
                bleStatusSection
                discoveredDevicesSection
                gogglePairingSection
                currentUIDSection
                osdTestSection
            }
            .navigationTitle("Connection")
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
        Section("Goggle Pairing") {
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
                Text("Put your goggles in bind mode, then tap Send Bind Packet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Apply UID") {
                applyUID()
            }
            .disabled(!canApplyUID)

            if selectedMode == .newPairing {
                Button("Send Bind Packet") {
                    bluetooth.sendBindCommand()
                }
                .disabled(!bluetooth.isConnected)
            }
        }
    }

    @ViewBuilder
    private var currentUIDSection: some View {
        if let uid = bluetooth.currentUID {
            Section("Current UID") {
                Text(formatUID(uid))
                    .font(.body.monospaced())
                    .textSelection(.enabled)
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

    private func applyUID() {
        let mode: UIDMode
        switch selectedMode {
        case .bindPhrase:
            mode = .bindPhrase(bindPhrase)
        case .manualUID:
            guard case .success(let uid) = parseUID(manualUIDText) else { return }
            mode = .manualUID(normalizeUID(uid))
        case .newPairing:
            mode = .newPairing
        }
        bluetooth.sendUIDConfig(mode: mode)
    }
}
