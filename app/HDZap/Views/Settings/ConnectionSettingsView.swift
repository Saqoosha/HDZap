import SwiftUI
import CoreBluetooth

/// M5StickS3 connection sub-screen: connected device + battery +
/// discovered list + scan trigger. Reachable from the M5StickS3 row in
/// the Settings root's Device section. Lives on its own screen so the
/// discovered list has room to grow without crowding the root list.
struct ConnectionSettingsView: View {
    @Environment(BluetoothManager.self) private var bluetooth

    #if DEBUG
    @State private var ssGoRename = false
    @State private var ssRouteApplied = false
    #endif

    var body: some View {
        List {
            connectedSection
            renameSection
            discoveredSection
            scanSection
        }
        .navigationTitle("M5StickS3")
        .navigationBarTitleDisplayMode(.inline)
        #if DEBUG
        .navigationDestination(isPresented: $ssGoRename) {
            DeviceRenameView()
        }
        .onAppear {
            guard !ssRouteApplied else { return }
            if ScreenshotMode.route == .rename {
                ssRouteApplied = true
                ssGoRename = true
            }
        }
        #endif
    }

    @ViewBuilder
    private var renameSection: some View {
        // Only surface the rename drilldown when paired against firmware
        // that carries CHR_DEVICE_NAME — older firmware would silently
        // 404 the write. `supportsDeviceRename` flips false on
        // disconnect, so the row also hides when offline (renaming
        // requires a live connection anyway).
        if bluetooth.isConnected && bluetooth.supportsDeviceRename {
            Section {
                NavigationLink {
                    DeviceRenameView()
                } label: {
                    LabeledContent("Bluetooth name") {
                        Text(bluetooth.currentDeviceName
                             ?? bluetooth.connectedDeviceName
                             ?? "—")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
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

                versionRow
            }
        }
    }

    /// App + firmware version row. Hidden until the firmware version
    /// characteristic has been read (the connected section is otherwise
    /// already populated with name + battery, so a brief absence here
    /// won't look broken). When the firmware reports a major version
    /// that disagrees with the app's, the row turns into an inline
    /// warning so the user has a place to see the version pair after
    /// dismissing the top-of-screen error banner.
    @ViewBuilder
    private var versionRow: some View {
        if let fw = bluetooth.firmwareVersion {
            let app = BluetoothManager.appVersionString() ?? "?"
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Version")
                    if bluetooth.firmwareIncompatible {
                        Text(BluetoothManager.firmwareMismatchSummary)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("App \(app)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("FW \(fw)")
                        .font(.caption)
                        .foregroundStyle(bluetooth.firmwareIncompatible ? .red : .secondary)
                }
            }
        }
    }

    private var discoveredSection: some View {
        let others = bluetooth.discoveredDevices
            .filter { $0.identifier != bluetooth.connectedIdentifier }
        return Section("Other devices") {
            #if DEBUG
            // Screenshot capture: render fake rows when the screenshot seed
            // populated them. `CBPeripheral` has no public initializer, so
            // we can't push entries onto `discoveredDevices` directly. The
            // production scan path leaves `screenshotDiscoveredDevices`
            // empty so this branch only renders when an explicit seed put
            // values in it.
            if !bluetooth.screenshotDiscoveredDevices.isEmpty {
                ForEach(bluetooth.screenshotDiscoveredDevices) { device in
                    HStack {
                        Circle()
                            .stroke(.secondary, lineWidth: 1)
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading) {
                            Text(device.name).font(.body)
                            Text(device.id.uuidString.prefix(8) + "...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Connect") {}
                            .buttonStyle(.bordered)
                            .disabled(true)
                    }
                }
            } else {
                realDiscoveredContent(others)
            }
            #else
            realDiscoveredContent(others)
            #endif
        }
    }

    @ViewBuilder
    private func realDiscoveredContent(_ others: [CBPeripheral]) -> some View {
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
                        Text(bluetooth.displayName(for: peripheral) ?? "Unknown").font(.body)
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

    private var scanSection: some View {
        Section {
            Button(bluetooth.isScanning ? "Scanning…" : "Scan") {
                bluetooth.startScan()
            }
            .disabled(bluetooth.isScanning)
        }
    }
}
