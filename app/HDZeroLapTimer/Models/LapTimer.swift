import Foundation

struct Lap: Identifiable {
    let id: Int
    let time: TimeInterval
}

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

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startDate = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, let startDate = self.startDate else { return }
            self.elapsedTime = self.accumulatedTime + Date().timeIntervalSince(startDate)
        }
    }

    @discardableResult
    func lap() -> Lap {
        let lapTime: TimeInterval
        if let lastLap = laps.last {
            lapTime = elapsedTime - laps.reduce(0) { $0 + $1.time }
        } else {
            lapTime = elapsedTime
        }
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
        laps = []
    }
}
