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
    var lastError: String?

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var userInitiatedDisconnect = false

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func clearError() { lastError = nil }

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

    @discardableResult
    func sendUIDConfig(mode: UIDMode) -> Bool {
        var data = Data()
        switch mode {
        case .bindPhrase(let phrase):
            data.append(0x01)
            data.append(contentsOf: phrase.utf8)
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
        write(data: Data([0x01]), to: bindCommandUUID)
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
        connectedDeviceName = peripheral.name
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
        if let error {
            lastError = "Disconnected: \(error.localizedDescription)"
        }
        if userInitiatedDisconnect {
            userInitiatedDisconnect = false
            connectedPeripheral = nil
            return
        }
        // Auto-reconnect: iOS will retry indefinitely in the background.
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
            lastError = "Write failed: \(error.localizedDescription)"
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == statusUUID, let data = characteristic.value, data.count >= 8 else { return }
        // Format: [connected:u8][uid:6bytes][lap_count:u8]
        currentUID = Array(data[1...6])
        lapCount = data[7]
    }
}
