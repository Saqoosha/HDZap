#if DEBUG
import Foundation

/// Synthetic `RaceRecord` factory used by Settings → Debug → Voltage
/// chart preview. Lets the editorial chart layout be eyeballed on
/// device without persisting a fake race into the user's history.
///
/// Wrapped in `#if DEBUG` so release builds never link this scaffold.
/// Remove the file (and the corresponding entry in
/// `SettingsView.debugSection`) once the chart design is finalised.
enum VoltageChartPreview {
    /// Builds a 90-s race with six laps and 23 CRSF Battery samples at
    /// a ~0.25 Hz fixture cadence — toward the lower end of the
    /// observed Betaflight range (typically ~0.25 Hz on the default
    /// config, up to ~1 Hz with adjusted sensor rate). Slower cadence
    /// keeps the dot count modest so the per-sample circles stay
    /// distinct on screen. Voltage sags from ~16.4 V to ~14.1 V with a
    /// sin-shaped throttle wobble so the chart's min-voltage accent
    /// dot is somewhere mid-race rather than always on the last sample.
    static func sampleRecord() -> RaceRecord {
        let now = Date()
        let startedAt = now.addingTimeInterval(-90)

        let laps: [Lap] = [
            Lap(id: 1, time: 14.32),
            Lap(id: 2, time: 13.95),
            Lap(id: 3, time: 14.10),
            Lap(id: 4, time: 13.78),
            Lap(id: 5, time: 14.55),
            Lap(id: 6, time: 14.22),
        ]

        let samples: [RaceFlightBatterySample] = (0..<23).map { i in
            let t = TimeInterval(i) * 4.0  // ~0.25 Hz fixture (slow end of Betaflight range), last sample at t=88 < 90 s
            let progress = t / 90.0
            // Linear sag with a 0.4 rad/s sin throttle wobble — gives a
            // visible mid-race dip the min-voltage accent dot can land on.
            let baseV = 16.42 - progress * 2.32
            let swing = sin(t * 0.45) * 0.18
            let v = baseV + swing
            let amps = 12.0 + sin(t * 0.5) * 6.5
            let mah = Int(progress * 1450)
            let pct = max(20, Int(95.0 - progress * 75.0))
            return RaceFlightBatterySample(
                tRace: t,
                receivedAt: startedAt.addingTimeInterval(t),
                voltageDv: Int((v * 10).rounded()),
                currentDa: Int((amps * 10).rounded()),
                consumedMah: mah,
                remainingPercent: pct
            )
        }

        // The factory always succeeds for these inputs (laps non-empty,
        // session/target valid, samples chronological). The deliberate
        // `fatalError` is a "this preview is broken — fix it before
        // showing the user" signal rather than silently rendering an
        // empty record. DEBUG-only code, won't reach a release build.
        guard let record = RaceRecord.snapshot(
            laps: laps,
            startedAt: startedAt,
            endedAt: now,
            sessionLimit: 90,
            targetLapCount: 6,
            accentHue: EditorialTheme.defaultAccentHue,
            flightBatterySamples: samples
        ) else {
            fatalError("VoltageChartPreview.sampleRecord: synthetic inputs failed validation")
        }
        return record
    }
}
#endif
