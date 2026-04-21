import SwiftUI

struct LapListView: View {
    let laps: [Lap]
    let bestLapIndex: Int?

    var totalTime: TimeInterval {
        laps.reduce(0) { $0 + $1.time }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if laps.isEmpty {
                ContentUnavailableView("No Laps", systemImage: "flag.slash",
                                       description: Text("Tap LAP to record"))
            } else {
                List {
                    ForEach(laps.reversed()) { lap in
                        let index = laps.firstIndex(where: { $0.id == lap.id })!
                        let isBest = index == bestLapIndex

                        HStack {
                            Text("#\(String(format: "%02d", lap.id))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Text(formatTime(lap.time))
                                .font(.body.monospacedDigit())
                                .fontWeight(isBest ? .bold : .regular)

                            Spacer()

                            if let bestIdx = bestLapIndex, !isBest {
                                let delta = lap.time - laps[bestIdx].time
                                Text("+\(formatTime(delta))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }

                            if isBest {
                                Text("BEST")
                                    .font(.caption.bold())
                                    .foregroundStyle(.orange)
                            }
                        }
                        .listRowBackground(isBest ? Color.orange.opacity(0.1) : Color.clear)
                    }

                    HStack {
                        Text("Total")
                            .font(.subheadline.bold())
                        Text(formatTime(totalTime))
                            .font(.body.monospacedDigit().bold())
                    }
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
            }
        }
    }
}

private func formatTime(_ interval: TimeInterval) -> String {
    let totalMs = Int(interval * 1000)
    let minutes = totalMs / 60_000
    let seconds = (totalMs % 60_000) / 1000
    let millis = totalMs % 1000
    return String(format: "%02d:%02d.%03d", minutes, seconds, millis)
}
