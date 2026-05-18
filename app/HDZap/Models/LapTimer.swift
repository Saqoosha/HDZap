import Foundation

struct Lap: Identifiable {
    let id: Int
    let time: TimeInterval
}

@MainActor
@Observable
class LapTimer {
    private(set) var elapsedTime: TimeInterval = 0
    private(set) var laps: [Lap] = []
    private(set) var isRunning = false
    /// Wall-clock timestamp of the first `start()` since the last
    /// `reset()`. Pause/resume (STOP→START) preserves it so a saved race
    /// reflects when the operator actually began the run, not the resume.
    private(set) var sessionStartedAt: Date?

    var bestLapIndex: Int? {
        guard !laps.isEmpty else { return nil }
        return laps.enumerated().min(by: { $0.element.time < $1.element.time })?.offset
    }

    private var timer: Timer?
    private var startDate: Date?
    private var accumulatedTime: TimeInterval = 0
    private var cumulativeLapTime: TimeInterval = 0

    init() {
        #if DEBUG
        // App Store screenshot seed runs at init() so the first render
        // already sees `isRunning == true` and the seeded laps. Flipping
        // state post-render via `.onAppear` exposes the primary button's
        // pulse-scale animation (driven by
        // `.onChange(of: lapTimer.isRunning)` + an explicit easeInOut
        // .animation modifier at the button site) and risks an unstable
        // label / pulse frame at capture time. See
        // docs/screenshot-capture.md.
        if ProcessInfo.processInfo.arguments.contains("-screenshotTimer") {
            seedForScreenshot(
                lapTimes: [15.55, 15.68, 14.67, 14.87],
                currentLapElapsed: 4.045
            )
        }
        #endif
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startDate = Date()
        if sessionStartedAt == nil {
            sessionStartedAt = startDate
        }
        // 60 Hz matches typical display refresh and keeps ms-digit rendering smooth.
        // Register on .common so the timer keeps firing during scroll /
        // tracking runloop modes (default `.scheduledTimer` uses .default,
        // which pauses). Bounce into @MainActor via Task rather than
        // MainActor.assumeIsolated — assumeIsolated traps on precondition
        // failure if the callback ever runs off the main queue, and that
        // failure mode would be silent under future concurrency changes.
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startDate = self.startDate else { return }
                self.elapsedTime = self.accumulatedTime + Date().timeIntervalSince(startDate)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @discardableResult
    func lap() -> Lap? {
        guard isRunning else { return nil }
        // Snapshot elapsed at the instant of the tap rather than reading
        // the 60 Hz-sampled value to keep lap boundaries accurate.
        if let startDate {
            elapsedTime = accumulatedTime + Date().timeIntervalSince(startDate)
        }
        let lapTime = elapsedTime - cumulativeLapTime
        cumulativeLapTime = elapsedTime
        let newLap = Lap(id: laps.count + 1, time: lapTime)
        laps.append(newLap)
        return newLap
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let startDate {
            accumulatedTime += Date().timeIntervalSince(startDate)
        }
        timer?.invalidate()
        timer = nil
        startDate = nil
    }

    func reset() {
        stop()
        elapsedTime = 0
        accumulatedTime = 0
        cumulativeLapTime = 0
        laps = []
        sessionStartedAt = nil
    }

    #if DEBUG
    /// Pre-populate state for App Store screenshot capture. Bypasses the
    /// normal start()/lap() sequence to land specific lap times. `isRunning`
    /// is flipped on so the view renders the LIVE state, but the 60 Hz
    /// timer is NOT started — the elapsed value stays frozen at the seeded
    /// total so the capture timing can drift without changing the
    /// displayed clock. `startDate` intentionally stays nil so the
    /// `if let startDate` guards in `lap()` / `stop()` short-circuit the
    /// elapsed-recompute, keeping the frozen state coherent even if those
    /// paths fire during capture. A subsequent `start()` resumes from the
    /// seeded `accumulatedTime`. See docs/screenshot-capture.md.
    func seedForScreenshot(lapTimes: [TimeInterval], currentLapElapsed: TimeInterval) {
        var cumulative: TimeInterval = 0
        var seeded: [Lap] = []
        for (i, t) in lapTimes.enumerated() {
            cumulative += t
            seeded.append(Lap(id: i + 1, time: t))
        }
        laps = seeded
        cumulativeLapTime = cumulative
        let total = cumulative + currentLapElapsed
        elapsedTime = total
        accumulatedTime = total
        sessionStartedAt = Date(timeIntervalSinceNow: -total)
        isRunning = true
    }
    #endif
}
