import SwiftUI

/// Single-screen race face — phase pip, big seconds, lap counter,
/// workout-active dot. No tabs, no controls — the watch is a haptic
/// surface and a glance. Race start/stop happens on the iPhone.
struct RaceFaceView: View {
    @Environment(RaceCoordinator.self) private var coordinator
    @State private var nowTick: Date = .init()

    /// 4 Hz redraw — fast enough for the seconds digit to feel live,
    /// slow enough to not chew battery during a workout. The
    /// scheduler doesn't depend on this — the view tick is purely
    /// cosmetic, all timing happens in `HapticScheduler`.
    private let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        // The watch's safe area is asymmetric — the system clock at
        // the top occupies a ~24 pt inset, but the bottom edge has
        // none. Centering the digits inside the safe area therefore
        // *visually* shifts them below the screen midpoint by half
        // that inset (~12 pt on the SE 3). Position the digits in
        // absolute coordinates against the GeometryProxy so they sit
        // at the screen's geometric center regardless of which watch
        // size we're running on — phasePip and lapAndWorkoutRow stay
        // inside the safe area as a normal VStack overlay.
        GeometryReader { geo in
            ZStack {
                remainingDigits
                    .position(
                        x: geo.size.width / 2,
                        // Bias the digits toward screen-center with a
                        // *quarter* of the top safe-area inset rather
                        // than half. Half over-shot — the rendered
                        // glyph's bounding box already includes empty
                        // descender space below the cap, so its visual
                        // midpoint sits a few points above the bbox
                        // midpoint. A quarter-inset offset lands the
                        // visual midpoint close to the screen
                        // midpoint without overcompensating into "a
                        // bit upper" territory.
                        y: geo.size.height / 2 - geo.safeAreaInsets.top / 4
                    )
                VStack(spacing: 0) {
                    phasePip
                    Spacer(minLength: 0)
                    lapAndWorkoutRow
                }
            }
        }
        .containerBackground(.black.gradient, for: .navigation)
        .onReceive(tick) { now in nowTick = now }
        .onAppear {
            coordinator.primeAuthorizationIfNeeded()
        }
    }

    // MARK: - Pieces

    private var phasePip: some View {
        Text(phaseLabel)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(phaseColor)
            .textCase(.uppercase)
            .tracking(1.5)
    }

    private var remainingDigits: some View {
        // Big seconds-only readout. The operator races with their
        // attention on the drone, not the watch — sub-second
        // precision is wasted area here.
        Text(remainingText)
            .font(.system(size: 64, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .minimumScaleFactor(0.5)
            .lineLimit(1)
    }

    private var lapAndWorkoutRow: some View {
        HStack(spacing: 10) {
            Text(lapText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            if coordinator.isWorkoutActive {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                Text("ARMED")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(.green)
            } else if let err = coordinator.workoutError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Derived

    private var phaseLabel: String {
        guard let s = coordinator.snapshot else { return "Waiting" }
        switch s.phase {
        case .idle: return "Ready"
        case .running: return "Live"
        case .paused: return "Paused"
        case .ended: return "Done"
        }
    }

    private var phaseColor: Color {
        guard let s = coordinator.snapshot else { return .gray }
        switch s.phase {
        case .idle: return .gray
        case .running: return .orange
        case .paused: return .yellow
        case .ended: return .red
        }
    }

    private var remainingText: String {
        guard let s = coordinator.snapshot else { return "—" }
        let secs = Int(s.remaining(at: nowTick).rounded())
        return "\(secs)"
    }

    private var lapText: String {
        guard let s = coordinator.snapshot else { return "" }
        return "Lap \(s.lapCount) / \(s.targetLapCount)"
    }
}
