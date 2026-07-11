import Foundation

extension RaceRecord {
    /// CSV for Apple Watch heart-rate samples captured during this race.
    func heartRateCSVText() -> String {
        guard !heartRateSamples.isEmpty else { return "" }
        var lines: [String] = [
            "t_race_s,received_at,bpm",
        ]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for s in heartRateSamples {
            lines.append([
                String(format: "%.3f", s.tRace),
                iso.string(from: s.receivedAt),
                "\(s.bpm)",
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func heartRateSummaryLines() -> [String] {
        guard let first = heartRateSamples.first else { return [] }
        guard let last = heartRateSamples.last else { return [] }
        let bpmMin = heartRateSamples.map(\.bpm).min() ?? last.bpm
        let bpmMax = heartRateSamples.map(\.bpm).max() ?? last.bpm
        let bpmAvg = Double(heartRateSamples.map(\.bpm).reduce(0, +))
            / Double(heartRateSamples.count)
        return [
            "\(heartRateSamples.count) heart-rate samples",
            String(format: "HR %d → %d bpm · min %d · avg %.0f · max %d",
                   first.bpm,
                   last.bpm,
                   bpmMin,
                   bpmAvg,
                   bpmMax),
        ]
    }
}
