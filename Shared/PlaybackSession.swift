import Foundation

enum PlaybackClock {
    private static let origin = ContinuousClock().now

    static var now: TimeInterval {
        let start = origin
        let parts = start.duration(to: ContinuousClock().now).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

struct PlaybackSession: Equatable {
    static let fadeDuration: TimeInterval = 10

    enum Pause: Equatable {
        case manual
        case interruption(output: [String])
        case routeLost
        case failure
    }

    let id = UUID()
    var preset: FanPreset
    let night: String?
    private(set) var deadline: TimeInterval?
    private(set) var pause: Pause?

    init(preset: FanPreset, now: TimeInterval, night: String? = nil) {
        self.preset = preset
        self.night = night
        deadline = preset.timer.seconds.map { now + $0 }
    }

    var isPlaying: Bool { pause == nil }

    func remaining(at now: TimeInterval) -> TimeInterval? {
        deadline.map { max(0, $0 - now) }
    }

    func hasEnded(at now: TimeInterval) -> Bool {
        deadline.map { now >= $0 } ?? false
    }

    static func fadeMultiplier(deadline: TimeInterval?, now: TimeInterval) -> Float {
        guard let deadline else { return 1 }
        return Float(min(1, max(0, (deadline - now) / fadeDuration)))
    }

    mutating func changeTimer(_ timer: FanTimer, at now: TimeInterval) {
        preset.timer = timer
        deadline = timer.seconds.map { now + $0 }
    }

    mutating func suspend(_ reason: Pause) {
        if pause == .routeLost, case .interruption = reason { return }
        pause = reason
    }

    mutating func resume(at now: TimeInterval) -> Bool {
        guard pause != nil, !hasEnded(at: now) else { return false }
        pause = nil
        return true
    }

    func canResumeAfterInterruption(id: UUID?, allowed: Bool, output: [String], now: TimeInterval) -> Bool {
        guard id == self.id, allowed, !hasEnded(at: now),
              case .interruption(let priorOutput) = pause else { return false }
        return !output.isEmpty && output == priorOutput
    }
}
