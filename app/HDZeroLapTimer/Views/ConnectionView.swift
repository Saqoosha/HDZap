import SwiftUI
import CoreBluetooth

struct ConnectionView: View {
    @Environment(BluetoothManager.self) private var bluetooth

    @State private var selectedMode = 0 // 0: bind phrase, 1: manual UID, 2: new pairing
    @State private var bindPhrase = ""
    @State private var manualUIDText = ""

    var body: some View {
        NavigationStack {
            List {
                bleStatusSection
                discoveredDevicesSection
                gogglePairingSection
                currentUIDSection
            }
            .navigationTitle("Connection")
        }
    }

    // MARK: - Sections

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

            if let peripheral = bluetooth.discoveredDevices.first(where: { _ in bluetooth.isConnected }) {
                HStack {
                    Text("Device")
                    Spacer()
                    Text(peripheral.name ?? "Unknown")
                        .foregroundStyle(.secondary)
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
                Text("Bind Phrase").tag(0)
                Text("Manual UID").tag(1)
                Text("New Pairing").tag(2)
            }
            .pickerStyle(.segmented)

            switch selectedMode {
            case 0:
                TextField("Bind phrase", text: $bindPhrase)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !bindPhrase.isEmpty {
                    let uid = uidFromBindPhrase(bindPhrase)
                    Text("UID: \(formatUID(uid))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            case 1:
                TextField("AA:BB:CC:DD:EE:FF", text: $manualUIDText)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
            default:
                Text("Put your goggles in bind mode, then tap Send Bind Packet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Apply UID") {
                applyUID()
            }
            .disabled(!canApplyUID)

            if selectedMode == 2 {
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

    // MARK: - Logic

    private var canApplyUID: Bool {
        guard bluetooth.isConnected else { return false }
        switch selectedMode {
        case 0: return !bindPhrase.isEmpty
        case 1: return parseUID(manualUIDText) != nil
        case 2: return true
        default: return false
        }
    }

    private func applyUID() {
        let mode: UIDMode
        switch selectedMode {
        case 0:
            mode = .bindPhrase(bindPhrase)
        case 1:
            guard let uid = parseUID(manualUIDText) else { return }
            mode = .manualUID(uid)
        default:
            mode = .newPairing
        }
        bluetooth.sendUIDConfig(mode: mode)
    }
}
