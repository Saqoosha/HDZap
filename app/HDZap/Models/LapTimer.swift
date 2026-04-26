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

    var bestLapIndex: Int? {
        guard !laps.isEmpty else { return nil }
        return laps.enumerated().min(by: { $0.element.time < $1.element.time })?.offset
    }

    private var timer: Timer?
    private var startDate: Date?
    private var accumulatedTime: TimeInterval = 0
    private var cumulativeLapTime: TimeInterval = 0

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startDate = Date()
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
    }
}
