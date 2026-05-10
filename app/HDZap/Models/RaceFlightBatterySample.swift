import Foundation

/// One CRSF Battery (0x08) observation during a saved race (`VER:1` wire from firmware).
///
/// Stored as raw CRSF-aligned integer units so persisted JSON survives display tweaks.
/// - `voltageDv`: decivolts — voltage in \(0.1\) V increments.
/// - `currentDa`: deciamps — current in \(0.1\) A increments.
/// - `remainingPercent`: CRSF telemetry percent (often −1 when unknown/disabled upstream).
struct RaceFlightBatterySample: Codable, Equatable {
    /// Seconds elapsed since race `startedAt`; non-negative within valid races.
    let tRace: TimeInterval
    /// Absolute wall-clock `.now` snapshot when BLE notify landed (telemetry path latency).
    let receivedAt: Date
    let voltageDv: Int
    let currentDa: Int
    let consumedMah: Int
    let remainingPercent: Int

    var voltageVolts: Double { Double(voltageDv) / 10.0 }
    var currentAmps: Double { Double(currentDa) / 10.0 }

    init(tRace: TimeInterval, receivedAt: Date, voltageDv: Int, currentDa: Int, consumedMah: Int, remainingPercent: Int) {
        self.tRace = tRace
        self.receivedAt = receivedAt
        self.voltageDv = voltageDv
        self.currentDa = currentDa
        self.consumedMah = consumedMah
        self.remainingPercent = remainingPercent
    }

    /// Decoded fields from one v1 wire frame, before race-relative
    /// timing is attached. Single source of the byte layout — both the
    /// race-recorder (`parseWireV1`) and `BluetoothManager`'s notify
    /// handler decode through here so a future change to the firmware
    /// frame format only edits one site.
    struct Fields: Equatable {
        let voltageDv: Int
        let currentDa: Int
        let consumedMah: Int
        let remainingPercent: Int
    }

    /// Firmware v1 notify: `[ver:1][flags:1][volt:2 LE][curr:2 LE][mah:3 LE][rem:1 signed]`
    /// `Data` subscripts honour `startIndex`, so a future caller passing
    /// a slice (e.g. `data[2...]`) would index out of bounds with bare
    /// `data[0]`. Add `startIndex` to every offset so slice-based callers
    /// work too — present callers always pass `characteristic.value`
    /// (start = 0), but the defence is essentially free.
    static func decodeFieldsV1(_ data: Data) -> Fields? {
        guard data.count >= 10 else { return nil }
        let s = data.startIndex
        guard data[s] == 1 else { return nil }
        return Fields(
            voltageDv: Int(Int16(bitPattern: UInt16(data[s + 2]) | (UInt16(data[s + 3]) << 8))),
            currentDa: Int(Int16(bitPattern: UInt16(data[s + 4]) | (UInt16(data[s + 5]) << 8))),
            consumedMah: Int(data[s + 6]) | (Int(data[s + 7]) << 8) | (Int(data[s + 8]) << 16),
            remainingPercent: Int(Int8(bitPattern: data[s + 9]))
        )
    }

    static func parseWireV1(_ data: Data, raceStartedAt: Date, now: Date = Date()) -> RaceFlightBatterySample? {
        guard let f = decodeFieldsV1(data) else { return nil }
        return RaceFlightBatterySample(
            tRace: now.timeIntervalSince(raceStartedAt),
            receivedAt: now,
            voltageDv: f.voltageDv,
            currentDa: f.currentDa,
            consumedMah: f.consumedMah,
            remainingPercent: f.remainingPercent
        )
    }
}
