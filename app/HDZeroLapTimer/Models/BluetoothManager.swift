import Foundation
import CoreBluetooth

enum OSDCommand: UInt8 {
    case clear = 0x01
    case resetLaps = 0x02
}

private let serviceUUID = CBUUID(string: "f47ac10b-58cc-4372-a567-0e02b2c3d479")
private let uidConfigUUID = CBUUID(string: "f47ac10b-58cc-4372-a567-0e02b2c3d481")
private let bindCommandUUID = CBUUID(string: "f47ac10b-58cc-4372-a567-0e02b2c3d482")
private let lapTimeUUID = CBUUID(string: "f47ac10b-58cc-4372-a567-0e02b2c3d483")
private let osdControlUUID = CBUUID(string: "f47ac10b-58cc-4372-a567-0e02b2c3d484")
private let statusUUID = CBUUID(string: "f47ac10b-58cc-4372-a567-0e02b2c3d485")

@MainActor
@Observable
class BluetoothManager: NSObject {
    private(set) var isConnected = false
    private(set) var isScanning = false
    private(set) var discoveredDevices: [CBPeripheral] = []
    private(set) var connectedDeviceName: String?
    private(set) var currentUID: [UInt8]?
    private(set) var lapCount: UInt8 = 0
    /// Recent errors, newest at index 0. Capped at `errorLogCapacity`;
    /// overflows and consecutive-duplicate collapses both increment
    /// `droppedErrorCount` so the UI can show "N more queued (+M dropped)"
    /// rather than losing the signal silently.
    private(set) var errorLog: [String] = []
    /// Errors that were dropped (either by overflow trimming or dedup
    /// collapsing a repeat). Cleared when `clearError()` empties the log
    /// or when `clearAllErrors()` is called explicitly.
    private(set) var droppedErrorCount = 0

    /// Single-string view of the top of `errorLog` (newest entry).
    /// - Getter returns `errorLog.first`.
    /// - Setter with a non-nil String calls `recordError`.
    /// - Setter with `nil` is shorthand for `clearAllErrors()`.
    /// Prefer `clearError()` for user-dismissed banners (pops one); reserve
    /// `clearAllErrors()` for explicit "Clear all" UX actions.
    var lastError: String? {
        get { errorLog.first }
        set {
            if let newValue {
                recordError(newValue)
            } else {
                clearAllErrors()
            }
        }
    }

    private static let errorLogCapacity = 5
    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var userInitiatedDisconnect = false

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    /// Dismiss the currently-displayed error. Other queued errors stay
    /// visible on the next tick so a burst isn't lost to one tap. When
    /// the log drains to empty, `droppedErrorCount` also resets so a
    /// stale "(+N dropped)" badge doesn't linger on the next new error.
    func clearError() {
        guard !errorLog.isEmpty else { return }
        errorLog.removeFirst()
        if errorLog.isEmpty {
            droppedErrorCount = 0
        }
    }

    /// Wipe the whole log plus the dropped counter.
    func clearAllErrors() {
        errorLog.removeAll()
        droppedErrorCount = 0
    }

    private func recordError(_ message: String) {
        // `@MainActor` on the class handles Swift callers; this runtime
        // assertion catches @objc bridged entry via CBCentralManagerDelegate
        // if its dispatch queue is ever changed away from main (today it's
        // `queue: nil` which maps to the main queue).
        MainActor.assertIsolated()
        // Collapse consecutive identical errors so an error storm doesn't
        // flood the ring — but count the collapsed ones so the user can
        // still see "(+N dropped)" rather than a single error hiding many.
        if errorLog.first == message {
            droppedErrorCount += 1
            return
        }
        errorLog.insert(message, at: 0)
        let overflow = errorLog.count - Self.errorLogCapacity
        if overflow > 0 {
            errorLog.removeLast(overflow)
            droppedErrorCount += overflow
        }
    }

    func startScan() {
        switch centralManager.state {
        case .poweredOn:
            break
        case .poweredOff:
            lastError = "Bluetooth is off. Enable it in Control Center."
            return
        case .unauthorized:
            lastError = "Bluetooth permission denied. Open Settings → HDZero → Bluetooth."
            return
        case .unsupported:
            lastError = "This device doesn't support Bluetooth LE."
            return
        default:
            lastError = "Bluetooth not ready (state \(centralManager.state.rawValue))."
            return
        }
        discoveredDevices = []
        isScanning = true
        centralManager.scanForPeripherals(withServices: [serviceUUID])
    }

    func stopScan() {
        centralManager.stopScan()
        isScanning = false
    }

    func connect(_ peripheral: CBPeripheral) {
        stopScan()
        userInitiatedDisconnect = false
        connectedPeripheral = peripheral
        centralManager.connect(peripheral)
    }

    func disconnect() {
        guard let peripheral = connectedPeripheral else { return }
        userInitiatedDisconnect = true
        centralManager.cancelPeripheralConnection(peripheral)
    }

    /// Bind phrases share a 63-byte cap with the firmware so the MD5 input
    /// (and therefore the derived UID) is identical on both sides.
    static let maxBindPhraseBytes = 63

    @discardableResult
    func sendUIDConfig(mode: UIDMode) -> Bool {
        var data = Data()
        switch mode {
        case .bindPhrase(let phrase):
            let bytes = Array(phrase.utf8)
            guard !bytes.isEmpty else {
                lastError = "Bind phrase is empty."
                return false
            }
            guard bytes.count <= Self.maxBindPhraseBytes else {
                lastError = "Bind phrase is \(bytes.count) bytes; max is \(Self.maxBindPhraseBytes)."
                return false
            }
            data.append(0x01)
            data.append(contentsOf: bytes)
        case .manualUID(let uid):
            guard uid.count == 6 else {
                lastError = "UID must be 6 bytes, got \(uid.count)."
                return false
            }
            data.append(0x02)
            data.append(contentsOf: uid)
        case .newPairing:
            data.append(0x03)
        }
        return write(data: data, to: uidConfigUUID)
    }

    @discardableResult
    func sendBindCommand() -> Bool {
        return write(data: Data([0x01]), to: bindCommandUUID)
    }

    @discardableResult
    func sendLapTime(lapNum: UInt8, timeMs: UInt32) -> Bool {
        var data = Data([lapNum])
        var ms = timeMs.littleEndian
        data.append(Data(bytes: &ms, count: 4))
        return write(data: data, to: lapTimeUUID)
    }

    @discardableResult
    func sendOSDControl(command: OSDCommand) -> Bool {
        write(data: Data([command.rawValue]), to: osdControlUUID)
    }

    @discardableResult
    private func write(data: Data, to uuid: CBUUID) -> Bool {
        guard let peripheral = connectedPeripheral else {
            lastError = "Not connected. Tap Scan and reconnect."
            return false
        }
        guard let characteristic = characteristics[uuid] else {
            lastError = "Characteristic not ready. Wait for discovery or reconnect."
            return false
        }
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
        return true
    }
}

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            isScanning = false
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if !discoveredDevices.contains(where: { $0.identifier == peripheral.identifier }) {
            discoveredDevices.append(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        // peripheral.name can be nil before the remote name is resolved; fall
        // back to a short identifier prefix so the UI shows *something* rather
        // than implying there's no active connection.
        connectedDeviceName = peripheral.name
            ?? "Device \(peripheral.identifier.uuidString.prefix(8))"
        peripheral.delegate = self
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        connectedPeripheral = nil
        connectedDeviceName = nil
        lastError = "Connection failed: \(error?.localizedDescription ?? "unknown"). Tap Scan to retry."
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        connectedDeviceName = nil
        characteristics = [:]
        if userInitiatedDisconnect {
            userInitiatedDisconnect = false
            connectedPeripheral = nil
            return
        }
        // Auto-reconnect: iOS will retry indefinitely in the background.
        // Don't flash the user a red error for a drop we're about to recover
        // from; only surface the disconnect reason via serial-level logging.
        if let error {
            print("BLE auto-reconnecting after disconnect: \(error.localizedDescription)")
        }
        centralManager.connect(peripheral)
    }
}

extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            lastError = "Service discovery failed: \(error.localizedDescription)"
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            lastError = "ESP32 doesn't advertise expected service. Update firmware?"
            return
        }
        peripheral.discoverCharacteristics([
            uidConfigUUID, bindCommandUUID, lapTimeUUID, osdControlUUID, statusUUID
        ], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            lastError = "Characteristic discovery failed: \(error.localizedDescription)"
            return
        }
        guard let chars = service.characteristics else { return }
        for char in chars {
            characteristics[char.uuid] = char
            if char.uuid == statusUUID {
                peripheral.setNotifyValue(true, for: char)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            lastError = "\(characteristicName(characteristic.uuid)) write failed: \(error.localizedDescription)"
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            // Notify error means we can't trust the last published status
            // frame any more — drop the derived fields so the UI doesn't
            // keep rendering values the firmware may have already changed.
            if characteristic.uuid == statusUUID {
                currentUID = nil
                lapCount = 0
            }
            lastError = "\(characteristicName(characteristic.uuid)) notify error: \(error.localizedDescription)"
            return
        }
        guard characteristic.uuid == statusUUID else { return }
        guard let data = characteristic.value, data.count >= 8 else {
            // Short frame points at firmware/app version skew — surface as
            // actionable error and invalidate the derived fields so the UI
            // doesn't keep showing a UID/lapCount that no longer reflects
            // the firmware.
            let n = characteristic.value?.count ?? 0
            currentUID = nil
            lapCount = 0
            lastError = "Status frame unexpected size (\(n)B, expected 8). Firmware/app version mismatch?"
            return
        }
        // Format: [connected:u8][uid:6bytes][lap_count:u8]
        currentUID = Array(data[1...6])
        lapCount = data[7]
    }

    private func characteristicName(_ uuid: CBUUID) -> String {
        switch uuid {
        case uidConfigUUID: return "UID config"
        case bindCommandUUID: return "Bind"
        case lapTimeUUID: return "Lap time"
        case osdControlUUID: return "OSD control"
        case statusUUID: return "Status"
        default: return uuid.uuidString
        }
    }
}
