import Foundation
import CoreBluetooth

enum OSDCommand: UInt8 {
    case clear = 0x01
    case resetLaps = 0x02
    /// Debug-only: fire a single test message ("HDZERO TEST") at the
    /// goggle OSD to verify ESP-NOW delivery end-to-end without having
    /// to start the timer and record a lap.
    case testOSD = 0x03
}

private let serviceUUID = CBUUID(string: "f47ac10b-58cc-4372-a567-0e02b2c3d479")
private let uidConfigUUID = CBUUID(string: "f47ac10b-58cc-4372-a567-0e02b2c3d481")
private let bindCommandUUID = CBUUID(string: "f47ac10b-58cc-4372-a567-0e02b2c3d482")
private let lapTimeUUID = CBUUID(string: "f47ac10b-58cc-4372-a567-0e02b2c3d483")
private let osdControlUUID = CBUUID(string: "f47ac10b-58cc-4372-a567-0e02b2c3d484")
private let statusUUID = CBUUID(string: "f47ac10b-58cc-4372-a567-0e02b2c3d485")
private let txSniffUUID = CBUUID(string: "f47ac10b-58cc-4372-a567-0e02b2c3d486")
private let osdTextUUID = CBUUID(string: "f47ac10b-58cc-4372-a567-0e02b2c3d487")

@MainActor
@Observable
class BluetoothManager: NSObject {
    private(set) var isConnected = false
    private(set) var isScanning = false

    /// True once we're connected AND the writeable characteristics have been
    /// discovered. Use this for any UI gate that depends on actually being
    /// able to write to the goggle — `isConnected` alone is true for the
    /// sub-second window between `didConnect` and `didDiscoverCharacteristics`,
    /// during which `write()` would fail with "characteristic not ready".
    var isReady: Bool {
        isConnected
            && characteristics[lapTimeUUID] != nil
            && characteristics[osdControlUUID] != nil
            && characteristics[osdTextUUID] != nil
    }

    private(set) var discoveredDevices: [CBPeripheral] = []
    private(set) var connectedDeviceName: String?
    private(set) var currentUID: [UInt8]?
    private(set) var lapCount: UInt8 = 0
    /// Latest Test OSD outcome from the firmware status notify.
    /// Encodes the `g_last_test_result` byte:
    ///   .none      = no test result yet (or the firmware byte was 0)
    ///   .ok        = ESP-NOW MAC layer ack'd every test packet
    ///   .lost      = at least one test packet was not delivered
    ///
    /// Bumped each time a fresh status frame arrives, regardless of whether
    /// the value changed. Drives the auto-test+rollback workflow in
    /// `ConnectionView` — that view tracks a sequence number from
    /// `testResultRevision` so it can ignore stale frames that arrived
    /// before its own pairing attempt.
    enum TestResult: UInt8 { case none = 0, ok = 1, lost = 2 }
    private(set) var lastTestResult: TestResult = .none
    private(set) var testResultRevision: UInt32 = 0
    /// UID we displaced on the most recent Apply attempt. Survives the
    /// Connection sheet being dismissed (which is why it lives here, not
    /// on the view) so the user can return to the sheet later and still
    /// tap Restore — even after a *successful* pairing, since "go back
    /// to my old goggle" is a real workflow.
    ///
    /// Replaced on every Apply attempt that has a known `currentUID` to
    /// displace; if `currentUID` is nil at Apply time, the prior stash is
    /// explicitly cleared instead so a UID from an earlier session can't
    /// be applied to the wrong M5Stick. Cleared by Restore taps and by
    /// the auto-rollback path inside `runPairingFlow` *only* when the
    /// rollback BLE write actually queued — failed dispatches keep the
    /// stash so the user can retry. Also cleared on intentional teardown
    /// (user disconnect, discovery failure, connect failure): those
    /// signal "different goggle next time, don't apply the previous
    /// one's UID by accident".
    private(set) var previousUID: [UInt8]?
    /// Most recently captured TX UID from a sniff session. Set when the
    /// firmware notifies via CHR_TX_SNIFF_UUID. Cleared on disconnect so
    /// a stale capture from a prior session can't be applied to the next M5Stick.
    private(set) var capturedTXUID: [UInt8]?
    /// True while the app has asked the firmware to listen for TX bind packets.
    /// Toggled locally on start/stop — firmware has no state echo.
    /// Intentionally preserved across auto-reconnects: the firmware recv
    /// callback survives BLE drops (only sniff_stop clears it), so both sides
    /// stay consistent without a reset. Cleared on user-initiated disconnect
    /// and tearDownConnection where firmware state is also discarded.
    private(set) var isTXSniffActive = false
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
        // Drop the rollback target — the next session is likely to talk to a
        // different M5Stick / goggle pair, and silently surfacing the prior
        // pair's UID as "Restore" would write the wrong value to the new one.
        previousUID = nil
        capturedTXUID = nil
        isTXSniffActive = false
        centralManager.cancelPeripheralConnection(peripheral)
    }

    /// Bind phrases share a 63-byte cap with the firmware so the MD5 input
    /// (and therefore the derived UID) is identical on both sides.
    static let maxBindPhraseBytes = 63

    /// Mark a UID as the rollback target. Call before sending a new UID
    /// config so a failed pairing can be reverted. Pass `nil` to clear —
    /// used by the manual Restore tap, the auto-rollback path inside
    /// `runPairingFlow`, and by Apply itself when no `currentUID` baseline
    /// exists yet.
    func recordPreviousUID(_ uid: [UInt8]?) {
        previousUID = uid
    }

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
    func sendOSDText(lines: [String]) -> Bool {
        guard lines.count == 3 else {
            lastError = "OSD text needs exactly 3 rows, got \(lines.count)."
            return false
        }

        for (row, line) in lines.enumerated() {
            var data = Data([UInt8(row)])
            data.append(Self.osdASCIIData(for: line))
            guard write(data: data, to: osdTextUUID) else { return false }
        }
        return true
    }

    @discardableResult
    func sendOSDControl(command: OSDCommand) -> Bool {
        write(data: Data([command.rawValue]), to: osdControlUUID)
    }

    @discardableResult
    func startTXSniff() -> Bool {
        let ok = write(data: Data([0x01]), to: txSniffUUID)
        if ok { isTXSniffActive = true }
        return ok
    }

    @discardableResult
    func stopTXSniff() -> Bool {
        let ok = write(data: Data([0x00]), to: txSniffUUID)
        if ok { isTXSniffActive = false }
        return ok
    }

    func clearCapturedTXUID() {
        capturedTXUID = nil
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

    private static func osdASCIIData(for line: String) -> Data {
        let ascii = line.uppercased().unicodeScalars.map { scalar -> UInt8 in
            scalar.isASCII ? UInt8(scalar.value) : 63
        }
        return Data(ascii.prefix(RaceMetrics.osdRowMaxBytes))
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
        // The connection never came up, so any rollback target tied to the
        // previous goggle is meaningless — drop it before the user reaches
        // for it on the wrong M5Stick.
        previousUID = nil
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
            uidConfigUUID, bindCommandUUID, lapTimeUUID, osdControlUUID, statusUUID, txSniffUUID, osdTextUUID
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
            if char.uuid == statusUUID || char.uuid == txSniffUUID {
                peripheral.setNotifyValue(true, for: char)
            }
        }
        // Point out schema mismatch explicitly rather than letting the user
        // tap Apply/Bind/Lap and hit the generic "Characteristic not ready"
        // error on every write. Missing characteristics almost always mean
        // firmware/app version skew — surface that directly.
        // txSniffUUID is intentionally excluded — it's optional (older firmware
        // won't advertise it) and its absence doesn't block core functionality.
        let expected: [CBUUID] = [uidConfigUUID, bindCommandUUID, lapTimeUUID, osdControlUUID, statusUUID, osdTextUUID]
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
        // Same reasoning as `disconnect()`: the next session will likely
        // be a different M5Stick / goggle, and a stale rollback UID would
        // be applied to the wrong device.
        previousUID = nil
        capturedTXUID = nil
        isTXSniffActive = false
        connectedPeripheral = nil
        characteristics = [:]
        suppressAutoReconnect = true
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == txSniffUUID {
            if let error {
                lastError = "TX sniff subscribe failed: \(error.localizedDescription). TX UID capture will not work."
            }
            return
        }
        // Gate on statusUUID so a future notify-on-another-characteristic
        // failure doesn't get misattributed as "Status subscribe failed".
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
        if characteristic.uuid == txSniffUUID {
            guard let data = characteristic.value, data.count == 6 else { return }
            capturedTXUID = Array(data)
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
            lastError = "Status frame unexpected size (\(n)B, expected ≥8). Firmware/app version mismatch?"
            return
        }
        // Format: [connected:u8][uid:6bytes][lap_count:u8][test_result:u8?]
        // The test_result byte was added in firmware commit "auto-test
        // result in status notify"; older firmware sends 8 bytes and we
        // simply leave lastTestResult at its previous value.
        currentUID = Array(data[1...6])
        lapCount = data[7]
        if data.count >= 9 {
            lastTestResult = TestResult(rawValue: data[8]) ?? .none
            // Bump even when the encoded value matches — observers want
            // to know "a fresh frame landed" not "a different result".
            testResultRevision &+= 1
        }
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
        case txSniffUUID: return "TX sniff"
        case osdTextUUID: return "OSD text"
        default: return uuid.uuidString
        }
    }
}
