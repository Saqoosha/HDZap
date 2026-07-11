import SwiftUI

/// Single-screen companion UI: live bpm read-out + workout toggle.
/// The normal flow is hands-off — open this app before flying and the
/// phone's race START/STOP drives the workout — so the button mostly
/// exists for warm-up (get HR lock before the race) and recovery when
/// the relay message was missed.
struct WatchContentView: View {
    @Environment(WatchWorkoutManager.self) private var workout

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, isActive: workout.isWorkoutRunning)
                Text("HDZAP")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text(workout.heartRateBpm.map(String.init) ?? "--")
                .font(.system(size: 54, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())

            Text("BPM")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            Button(workout.isWorkoutRunning ? "Stop" : "Start") {
                workout.toggleWorkout()
            }
            .tint(workout.isWorkoutRunning ? .red : .green)

            if let error = workout.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, 4)
    }
}
