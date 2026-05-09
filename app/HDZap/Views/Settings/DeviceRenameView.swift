import SwiftUI

/// Rename the M5StickS3's advertised BLE name. Reachable from the
/// M5StickS3 connection sub-screen. Saving triggers a firmware reboot
/// (BLEDevice::init is one-shot so a clean restart is cheaper than a
/// runtime BLE-stack teardown), and bonded iOS auto-reconnects with
/// the new name in scan results within a few seconds.
struct DeviceRenameView: View {
    @Environment(BluetoothManager.self) private var bluetooth
    @Environment(\.dismiss) private var dismiss

    @State private var draft: String = ""
    @FocusState private var nameFieldFocused: Bool

    /// UTF-8 byte budget mirrors the firmware-side cap. Counting bytes
    /// rather than characters because emoji / wide-script names eat the
    /// adv-packet budget faster than character count would suggest.
    private var byteCount: Int {
        Data(draft.trimmingCharacters(in: .whitespacesAndNewlines).utf8).count
    }

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        guard bluetooth.isReady, bluetooth.supportsDeviceRename else { return false }
        let n = byteCount
        return n > 0
            && n <= bleDeviceNameMaxBytes
            && trimmed != (bluetooth.currentDeviceName ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($nameFieldFocused)
                    .submitLabel(.done)
                    .onSubmit { if canSave { save() } }
            } header: {
                Text("Bluetooth name")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(byteCount) / \(bleDeviceNameMaxBytes) bytes")
                        .foregroundStyle(byteCount > bleDeviceNameMaxBytes ? .red : .secondary)
                        .monospacedDigit()
                    if !bluetooth.supportsDeviceRename {
                        Text("Connected firmware doesn't support renaming. Update firmware.")
                            .foregroundStyle(.orange)
                    } else if !bluetooth.isReady {
                        Text("Reconnect the M5StickS3 to rename it.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Saving reboots the M5StickS3. The connection drops for a few seconds, then iPhone reconnects automatically with the new name.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Rename device")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }
                    .disabled(!canSave)
            }
        }
        .onAppear {
            draft = bluetooth.currentDeviceName ?? bluetooth.connectedDeviceName ?? ""
            nameFieldFocused = true
        }
    }

    private func save() {
        if bluetooth.sendDeviceName(trimmed) {
            // Pop back so the user sees ConnectionSettingsView's
            // re-render across the brief disconnect → reconnect; the
            // alternative (staying on this screen with a stale draft
            // and an inert Save button) is just confusing.
            dismiss()
        }
    }
}
