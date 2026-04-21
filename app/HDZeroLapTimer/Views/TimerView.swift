import SwiftUI

struct TimerView: View {
    @Environment(LapTimer.self) private var lapTimer
    @Environment(BluetoothManager.self) private var bluetooth

    var body: some View {
        VStack(spacing: 16) {
            connectionStatus

            elapsedTimeDisplay

            latestLapCard

            lapButton

            controlButtons

            Text("Lap History")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

            LapListView(laps: lapTimer.laps, bestLapIndex: lapTimer.bestLapIndex)
        }
        .padding(.top)
    }

    // MARK: - Subviews

    private var connectionStatus: some View {
        HStack {
            Circle()
                .fill(bluetooth.isConnected ? .green : .red)
                .frame(width: 10, height: 10)
            Text(bluetooth.isConnected ? "Connected" : "Disconnected")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal)
    }

    private var elapsedTimeDisplay: some View {
        Text(formatTime(lapTimer.elapsedTime))
            .font(.system(size: 56, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .padding(.vertical, 8)
    }

    @ViewBuilder
    private var latestLapCard: some View {
        if let lastLap = lapTimer.laps.last {
            let isBest = lapTimer.bestLapIndex == lapTimer.laps.count - 1
            VStack(spacing: 4) {
                Text("LAP \(String(format: "%02d", lastLap.id))")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                Text(formatTime(lastLap.time))
                    .font(.system(size: 32, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(isBest ? .orange : .primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
        }
    }

    private var lapButton: some View {
        Button {
            recordLap()
        } label: {
            Text("LAP")
                .font(.system(size: 36, weight: .bold))
                .frame(maxWidth: .infinity)
                .frame(height: 88)
                .background(lapTimer.isRunning ? Color.accentColor : Color.gray)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .disabled(!lapTimer.isRunning)
        .padding(.horizontal)
    }

    private var controlButtons: some View {
        HStack(spacing: 16) {
            Button {
                if lapTimer.isRunning {
                    lapTimer.stop()
                } else {
                    lapTimer.start()
                }
            } label: {
                Text(lapTimer.isRunning ? "STOP" : "START")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(lapTimer.isRunning ? Color.red : Color.green)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            Button {
                bluetooth.sendOSDControl(command: .resetLaps)
                lapTimer.reset()
            } label: {
                Text("RESET")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color(.systemGray4))
                    .foregroundStyle(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(lapTimer.isRunning)
        }
        .padding(.horizontal)
    }

    // MARK: - Actions

    private func recordLap() {
        guard let lap = lapTimer.lap() else { return }
        let timeMs = UInt32(lap.time * 1000)
        // Wire format uses u8 lap num. Firmware caps laps at 99 (MAX_LAPS),
        // so wrapping is only a concern for runaway sessions; keep the wrap
        // documented rather than silently clamping to 255 forever.
        let lapByte = UInt8(truncatingIfNeeded: lap.id)
        bluetooth.sendLapTime(lapNum: lapByte, timeMs: timeMs)
    }
}

private func formatTime(_ interval: TimeInterval) -> String {
    let totalMs = Int(interval * 1000)
    let minutes = totalMs / 60_000
    let seconds = (totalMs % 60_000) / 1000
    let millis = totalMs % 1000
    return String(format: "%02d:%02d.%03d", minutes, seconds, millis)
}
