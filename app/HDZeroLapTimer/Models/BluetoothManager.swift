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
    /// `droppedErrorCount`, which the UI surfaces as
    /// "N more queued (+M suppressed)" so either form of lost signal is
    /// visible rather than silent.
    private(set) var errorLog: [String] = []
    /// Count of errors that were suppressed — either trimmed by overflow
    /// or collapsed as a repeat of the current head. Sticky across
    /// `clearError()` calls so an ongoing error storm stays visible after
    /// the user drains the queue; only `clearAllErrors()` zeroes it.
    /// Named `droppedErrorCount` for legacy reasons; the user-visible
    /// label is "suppressed".
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
    /// Suppresses iOS background auto-reconnect. Set by both `disconnect()`
    /// (user tapped Disconnect) and `tearDownConnection(_:)` (app-initiated
    /// abort after discovery failure). Consumed by `didDisconnectPeripheral`.
    private var suppressAutoReconnect = false
    /// Distinguishes "user actually tapped Disconnect" from other teardown
    /// sources. Used only by `centralManagerDidUpdateState` to decide
    /// whether to surface the BT-state banner — an app-initiated teardown
    /// has its own error message and shouldn't mask a concurrent BT-off.
    private var userTappedDisconnect = false

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    /// Dismiss the currently-displayed error. Other queued errors stay
    /// visible on the next tick so a burst isn't lost to one tap.
    /// `droppedErrorCount` stays sticky: an ongoing storm would otherwise
    /// look like a trickle once the user drains the queue. Use
    /// `clearAllErrors()` when the user explicitly wants to zero the log.
    func clearError() {
        guard !errorLog.isEmpty else { return }
        errorLog.removeFirst()
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
        suppressAutoReconnect = false
        userTappedDisconnect = false
        connectedPeripheral = peripheral
        centralManager.connect(peripheral)
    }

    func disconnect() {
        guard let peripheral = connectedPeripheral else { return }
        suppressAutoReconnect = true
        userTappedDisconnect = true
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
        if central.state == .poweredOn { return }
        isScanning = false
        // A mid-session state change (Bluetooth toggled off, permission
        // revoked, stack reset) leaves the cached peripheral stale —
        // CoreBluetooth needs cancelPeripheralConnection to keep its own
        // bookkeeping consistent, so route through tearDownConnection
        // instead of nil-ing the fields inline.
        guard isConnected, let peripheral = connectedPeripheral else { return }
        let wasUserTap = userTappedDisconnect
        tearDownConnection(peripheral)
        // Only a real user tap suppresses the state-change banner —
        // an app-initiated teardown (tearDownConnection from a discovery
        // failure) has its own error message but shouldn't mask a
        // concurrent BT-off event the user also needs to know about.
        if wasUserTap {
            // Consume the flag here so a later state change that isn't
            // user-initiated (e.g. BT toggled off during a subsequent
            // auto-reconnected session) doesn't inherit the suppression.
            userTappedDisconnect = false
            return
        }
        switch central.state {
        case .poweredOff:
            lastError = "Bluetooth turned off mid-session. Laps are not reaching the goggle — enable Bluetooth and tap Scan."
        case .unauthorized:
            lastError = "Bluetooth permission revoked. Re-grant in Settings → HDZero → Bluetooth."
        case .resetting:
            lastError = "Bluetooth stack resetting. Wait a moment, then tap Scan."
        case .unsupported:
            lastError = "This device no longer reports Bluetooth LE support."
        default:
            lastError = "Bluetooth unavailable (state \(central.state.rawValue))."
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
        // Clean slate for the intent flags on every successful connection,
        // regardless of which path (explicit connect() or iOS auto-reconnect
        // after an unexpected drop) got us here.
        suppressAutoReconnect = false
        userTappedDisconnect = false
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
        // Clear the disconnect-intent flags so the next connect() starts
        // from a clean slate — connect() already resets them, but making
        // it explicit here prevents stale flags leaking across sessions
        // if that reset path ever changes.
        suppressAutoReconnect = false
        userTappedDisconnect = false
        lastError = "Connection failed: \(error?.localizedDescription ?? "unknown"). Tap Scan to retry."
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        connectedDeviceName = nil
        characteristics = [:]
        if suppressAutoReconnect {
            suppressAutoReconnect = false
            userTappedDisconnect = false
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
            tearDownConnection(peripheral)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            lastError = "ESP32 doesn't advertise expected service. Update firmware?"
            tearDownConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([
            uidConfigUUID, bindCommandUUID, lapTimeUUID, osdControlUUID, statusUUID
        ], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        // Only process the service we actually care about — a future added
        // service on the peripheral would otherwise false-positive below.
        guard service.uuid == serviceUUID else { return }
        if let error {
            lastError = "Characteristic discovery failed: \(error.localizedDescription)"
            tearDownConnection(peripheral)
            return
        }
        // nil and empty are both "no characteristics reported" — fold them
        // together so the verification block runs uniformly.
        let chars = service.characteristics ?? []
        for char in chars {
            characteristics[char.uuid] = char
            if char.uuid == statusUUID {
                peripheral.setNotifyValue(true, for: char)
            }
        }
        // Point out schema mismatch explicitly rather than letting the user
        // tap Apply/Bind/Lap and hit the generic "Characteristic not ready"
        // error on every write. Missing characteristics almost always mean
        // firmware/app version skew — surface that directly.
        let expected: [CBUUID] = [uidConfigUUID, bindCommandUUID, lapTimeUUID, osdControlUUID, statusUUID]
        let missing = expected.filter { characteristics[$0] == nil }
        if !missing.isEmpty {
            let names = missing.map(characteristicName).joined(separator: ", ")
            lastError = "Firmware missing characteristics: \(names). Update firmware?"
            tearDownConnection(peripheral)
        }
    }

    /// Cancel the CB connection and zero the cached peripheral state.
    /// Called when we've surfaced an error that makes the current session
    /// unusable (wrong service, missing characteristics, discovery failure);
    /// leaving `isConnected = true` with an empty characteristics map would
    /// make every write fail with the generic "not ready" error.
    ///
    /// Sets `suppressAutoReconnect = true` so the upcoming
    /// `didDisconnectPeripheral` takes the early-return branch instead of
    /// triggering auto-reconnect — the flag does double duty as "user
    /// tapped Disconnect" (from `disconnect()`) and "internal teardown
    /// wants iOS not to retry" (from here). If that callback never fires
    /// (iOS can skip it when the peripheral was still in .connecting),
    /// the flag remains sticky until the next call to `connect(_:)`.
    private func tearDownConnection(_ peripheral: CBPeripheral) {
        centralManager.cancelPeripheralConnection(peripheral)
        isConnected = false
        connectedDeviceName = nil
        connectedPeripheral = nil
        characteristics = [:]
        suppressAutoReconnect = true
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        // Only the status characteristic uses notifications today; gate
        // on UUID so a future notify-on-another-characteristic failure
        // doesn't get misattributed as "Status subscribe failed".
        guard characteristic.uuid == statusUUID else { return }
        if let error {
            lastError = "Status subscribe failed: \(error.localizedDescription). Laps still send, but goggle state won't appear in-app."
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            lastError = formatBLEError(kind: "write failed", uuid: characteristic.uuid, error: error)
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
            lastError = formatBLEError(kind: "notify error", uuid: characteristic.uuid, error: error)
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

    /// Composed error message that keeps the underlying NSError domain +
    /// code in the text. Matters primarily for CoreBluetooth errors
    /// (`CBError`, `CBATTError`): two distinct codes that share a
    /// `localizedDescription` would otherwise dedup into one row and mask
    /// a shifting failure mode. Pure Swift errors bridge too, though the
    /// resulting domain string (e.g. "HDZeroLapTimer.MyError") is cosmetic
    /// noise rather than useful signal.
    private func formatBLEError(kind: String, uuid: CBUUID, error: Error) -> String {
        let ns = error as NSError
        return "\(characteristicName(uuid)) \(kind): \(error.localizedDescription) [\(ns.domain) \(ns.code)]"
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
