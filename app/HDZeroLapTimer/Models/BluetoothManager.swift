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

@Observable
class BluetoothManager: NSObject {
    private(set) var isConnected = false
    private(set) var isScanning = false
    private(set) var discoveredDevices: [CBPeripheral] = []
    private(set) var currentUID: [UInt8]?
    private(set) var lapCount: UInt8 = 0

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var pendingReconnect: CBPeripheral?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func startScan() {
        guard centralManager.state == .poweredOn else { return }
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
        connectedPeripheral = peripheral
        centralManager.connect(peripheral)
    }

    func disconnect() {
        guard let peripheral = connectedPeripheral else { return }
        pendingReconnect = nil
        centralManager.cancelPeripheralConnection(peripheral)
    }

    func sendUIDConfig(mode: UIDMode) {
        var data = Data()
        switch mode {
        case .bindPhrase(let phrase):
            data.append(0x01)
            data.append(contentsOf: phrase.utf8)
        case .manualUID(let uid):
            data.append(0x02)
            data.append(contentsOf: uid)
        case .newPairing:
            data.append(0x03)
        }
        write(data: data, to: uidConfigUUID)
    }

    func sendBindCommand() {
        write(data: Data([0x01]), to: bindCommandUUID)
    }

    func sendLapTime(lapNum: UInt8, timeMs: UInt32) {
        var data = Data([lapNum])
        var ms = timeMs.littleEndian
        data.append(Data(bytes: &ms, count: 4))
        write(data: data, to: lapTimeUUID)
    }

    func sendOSDControl(command: OSDCommand) {
        write(data: Data([command.rawValue]), to: osdControlUUID)
    }

    private func write(data: Data, to uuid: CBUUID) {
        guard let peripheral = connectedPeripheral,
              let characteristic = characteristics[uuid] else { return }
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
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
        peripheral.delegate = self
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        characteristics = [:]
        if pendingReconnect == nil {
            pendingReconnect = peripheral
            centralManager.connect(peripheral)
        }
    }
}

extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else { return }
        peripheral.discoverCharacteristics([
            uidConfigUUID, bindCommandUUID, lapTimeUUID, osdControlUUID, statusUUID
        ], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for char in chars {
            characteristics[char.uuid] = char
            if char.uuid == statusUUID {
                peripheral.setNotifyValue(true, for: char)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == statusUUID, let data = characteristic.value, data.count >= 8 else { return }
        // Format: [connected:u8][uid:6bytes][lap_count:u8]
        currentUID = Array(data[1...6])
        lapCount = data[7]
    }
}
