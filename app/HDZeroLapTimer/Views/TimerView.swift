import SwiftUI

struct TimerView: View {
    @Environment(LapTimer.self) private var lapTimer
    @Environment(BluetoothManager.self) private var bluetooth

    var body: some View {
        VStack(spacing: 16) {
            connectionStatus

            if let err = bluetooth.lastError {
                errorBanner(err)
            }

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

    private func errorBanner(_ message: String) -> some View {
        let remaining = max(bluetooth.errorLog.count - 1, 0)
        let suppressed = bluetooth.droppedErrorCount
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                if remaining > 0 || suppressed > 0 {
                    let suffix = suppressed > 0 ? " (+\(suppressed) suppressed)" : ""
                    Text("\(remaining) more queued\(suffix)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Button(remaining > 0 ? "Next" : "Dismiss") { bluetooth.clearError() }
                    .font(.caption)
                if remaining > 0 || suppressed > 0 {
                    Button("Clear all", role: .destructive) { bluetooth.clearAllErrors() }
                        .font(.caption2)
                }
            }
        }
        .padding(8)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
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
        let enabled = lapTimer.isRunning && bluetooth.isConnected
        return Button {
            recordLap()
        } label: {
            Text("LAP")
                .font(.system(size: 36, weight: .bold))
                .frame(maxWidth: .infinity)
                .frame(height: 88)
                .background(enabled ? Color.accentColor : Color.gray)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        // Require a BLE connection like RESET — a tap while disconnected
        // would leave the iOS lap list and the goggle OSD disagreeing
        // (lap stored locally, nothing reaches the goggle).
        .disabled(!enabled)
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
            // Require a BLE connection so a tap doesn't leave iOS and the
            // goggle in disagreement — local state would clear while the
            // goggle kept displaying the old lap table.
            .disabled(lapTimer.isRunning || !bluetooth.isConnected)
        }
        .padding(.horizontal)
    }

    // MARK: - Actions

    private func recordLap() {
        guard let lap = lapTimer.lap() else { return }
        // `UInt32(x)` traps on overflow or negatives. Clamp via Int64 instead
        // so a pathological multi-hour session can't crash the app.
        let rawMs = Int64((lap.time * 1000).rounded())
        let timeMs = UInt32(clamping: rawMs)
        // Wire format is u8 lap num. Firmware stores up to MAX_LAPS=99; iOS
        // keeps counting but truncating wraps at 256. Only a concern for
        // runaway sessions — firmware side caps its own display.
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
