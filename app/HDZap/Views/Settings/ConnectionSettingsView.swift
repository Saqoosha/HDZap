import SwiftUI
import CoreBluetooth

/// M5StickS3 connection sub-screen: connected device + battery +
/// discovered list + scan trigger. Reachable from the M5StickS3 row in
/// the Settings root's Device section. Lives on its own screen so the
/// discovered list has room to grow without crowding the root list.
struct ConnectionSettingsView: View {
    @Environment(BluetoothManager.self) private var bluetooth

    var body: some View {
        List {
            connectedSection
            discoveredSection
            scanSection
        }
        .navigationTitle("M5StickS3")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var connectedSection: some View {
        // Skipped only when name is missing (sub-second window between
        // didConnect and didDiscoverServices); the identifier-based
        // filter on the discovered list still hides this peripheral
        // there so it never appears twice.
        if bluetooth.isConnected, let name = bluetooth.connectedDeviceName {
            Section("Connected") {
                HStack {
                    Circle()
                        .fill(.green)
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading) {
                        Text(name).font(.body)
                        if let id = bluetooth.connectedIdentifier {
                            Text(id.uuidString.prefix(8) + "...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Disconnect", role: .destructive) {
                        bluetooth.disconnect()
                    }
                    .buttonStyle(.bordered)
                }

                BatteryStatusRow()

                FlightBatteryStatusRow()
            }
        }
    }

    private var discoveredSection: some View {
        let others = bluetooth.discoveredDevices
            .filter { $0.identifier != bluetooth.connectedIdentifier }
        return Section("Other devices") {
            if others.isEmpty {
                Text(bluetooth.isConnected
                     ? String(localized: "No other devices found.")
                     : String(localized: "No devices found. Tap Scan to search."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(others, id: \.identifier) { peripheral in
                    HStack {
                        Circle()
                            .stroke(.secondary, lineWidth: 1)
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading) {
                            Text(peripheral.name ?? "Unknown").font(.body)
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

    private var scanSection: some View {
        Section {
            Button(bluetooth.isScanning ? "Scanning…" : "Scan") {
                bluetooth.startScan()
            }
            .disabled(bluetooth.isScanning)
        }
    }
}
