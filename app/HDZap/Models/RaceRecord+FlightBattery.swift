import Foundation

extension RaceRecord {
    /// CSV for flight-pack CRSF battery telemetry captured during this race.
    func flightBatteryCSVText() -> String {
        guard !flightBatterySamples.isEmpty else { return "" }
        var lines: [String] = [
            "t_race_s,received_at,voltage_v,current_a,consumed_mah,remaining_pct",
        ]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for s in flightBatterySamples {
            lines.append([
                String(format: "%.3f", s.tRace),
                iso.string(from: s.receivedAt),
                String(format: "%.2f", s.voltageVolts),
                String(format: "%.2f", s.currentAmps),
                "\(s.consumedMah)",
                "\(s.remainingPercent)",
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func flightBatterySummaryLines() -> [String] {
        guard let first = flightBatterySamples.first else { return [] }
        guard let last = flightBatterySamples.last else { return [] }
        let vmin = flightBatterySamples.map(\.voltageVolts).min() ?? last.voltageVolts
        let vmax = flightBatterySamples.map(\.voltageVolts).max() ?? last.voltageVolts
        let imax = flightBatterySamples.map(\.currentAmps).max() ?? last.currentAmps
        let voltDropStartEnd = first.voltageVolts - last.voltageVolts
        let remDelta = last.remainingPercent - first.remainingPercent
        return [
            "\(flightBatterySamples.count) CRSF Battery samples",
            String(format: "Voltage %.1f → %.1f V (%+.2f drop start→end) · intra-race Δ%.2f V",
                   first.voltageVolts,
                   last.voltageVolts,
                   voltDropStartEnd,
                   vmax - vmin),
            String(format: "Max current %.1f A · consumed %d mAh (last) · remaining %d%% (%+d Δ)",
                   imax,
                   last.consumedMah,
                   last.remainingPercent,
                   remDelta),
        ]
    }
}
