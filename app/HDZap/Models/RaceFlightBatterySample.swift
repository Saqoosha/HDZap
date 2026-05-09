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

    /// Firmware v1 notify: `[ver:1][flags:1][volt:2 LE][curr:2 LE][mah:3 LE][rem:1 signed]`
    static func parseWireV1(_ data: Data, raceStartedAt: Date, now: Date = Date()) -> RaceFlightBatterySample? {
        guard data.count >= 10, data[0] == 1 else { return nil }
        let v = Int(Int16(bitPattern: UInt16(data[2]) | (UInt16(data[3]) << 8)))
        let c = Int(Int16(bitPattern: UInt16(data[4]) | (UInt16(data[5]) << 8)))
        let mah = Int(data[6]) | (Int(data[7]) << 8) | (Int(data[8]) << 16)
        let rem = Int(Int8(bitPattern: data[9]))
        let tRace = now.timeIntervalSince(raceStartedAt)
        return RaceFlightBatterySample(
            tRace: tRace,
            receivedAt: now,
            voltageDv: v,
            currentDa: c,
            consumedMah: mah,
            remainingPercent: rem
        )
    }
}
