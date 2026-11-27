import Foundation

/// Configuration for the camera-independent 20-20-20 eye-break timer.
public struct EyeBreakTimerConfig: Equatable {
    /// Whether automatic breaks are enabled.
    public var enabled: Bool
    /// Seconds between the end of one break and the start of the next.
    public var interval: TimeInterval
    /// How long the "look away" card stays up.
    public var restSeconds: TimeInterval

    public init(
        enabled: Bool = true,
        interval: TimeInterval = 20 * 60,
        restSeconds: TimeInterval = 20
    ) {
        precondition(interval > 0, "interval must be positive")
        precondition(restSeconds > 0, "rest duration must be positive")
        self.enabled = enabled
        self.interval = interval
        self.restSeconds = restSeconds
    }
}

/// What the caller should do after evaluating the timer.
public enum EyeBreakDecision: Equatable {
    case none
    case beginRest
    case endRest
    case suppressed(NudgeSuppression)
}

/// Pure, monotonic 20-20-20 timer.
///
/// One break is due every `interval` seconds and lasts `restSeconds`. The timer
/// owns no timers itself: the monitor arms a single tolerant one-shot timer at
/// `nextDeadline()` and calls `evaluate` when it wakes. Time is monotonic
/// seconds supplied by the caller, so wall-clock jumps cannot delay or duplicate
/// a break (same rule as `BlinkGapPolicy`).
public struct EyeBreakTimer {
    public private(set) var config: EyeBreakTimerConfig
    /// When the next automatic break is due, or nil while resting/disabled.
    public private(set) var nextBreakAt: TimeInterval?
    /// When the current rest ends, or nil when not resting.
    public private(set) var restEndsAt: TimeInterval?
    /// Number of breaks started (automatic and manual).
    public private(set) var breakCount = 0

    public var isResting: Bool { restEndsAt != nil }

    public init(config: EyeBreakTimerConfig = EyeBreakTimerConfig()) {
        self.config = config
    }

    /// Starts (or restarts) the cadence. The first break is one full interval
    /// away, so enabling breaks never nags immediately.
    public mutating func start(at now: TimeInterval) {
        restEndsAt = nil
        nextBreakAt = config.enabled ? now + config.interval : nil
    }

    public mutating func setEnabled(_ enabled: Bool, at now: TimeInterval) {
        guard config.enabled != enabled else { return }
        config.enabled = enabled
        if enabled {
            if restEndsAt == nil {
                nextBreakAt = now + config.interval
            }
        } else {
            nextBreakAt = nil
            restEndsAt = nil
        }
    }

    /// Re-arms from `now` so a new interval takes effect immediately.
    public mutating func setInterval(_ interval: TimeInterval, at now: TimeInterval) {
        guard interval > 0, config.interval != interval else { return }
        config.interval = interval
        if config.enabled, restEndsAt == nil {
            nextBreakAt = now + interval
        }
    }

    /// Changes the rest duration. A shorter duration can end the current rest
    /// sooner; a longer one never extends a rest already in progress.
    public mutating func setRestSeconds(_ seconds: TimeInterval, at now: TimeInterval) {
        guard seconds > 0, config.restSeconds != seconds else { return }
        config.restSeconds = seconds
        if let currentEnd = restEndsAt {
            restEndsAt = min(currentEnd, now + seconds)
        }
    }

    /// Manual "Take Eye Break Now". Restarts the rest window and resets the
    /// next automatic break to one full interval after the rest ends.
    @discardableResult
    public mutating func beginNow(at now: TimeInterval) -> EyeBreakDecision {
        guard config.enabled else { return .none }
        if restEndsAt == nil {
            breakCount += 1
        }
        restEndsAt = now + config.restSeconds
        nextBreakAt = nil
        return .beginRest
    }

    /// Evaluates the timer at `now`.
    ///
    /// A break that comes due while suppressed is skipped and rescheduled a
    /// full interval later instead of firing late (no catch-up after sleep,
    /// quiet hours or pause).
    @discardableResult
    public mutating func evaluate(
        now: TimeInterval,
        suppression: NudgeSuppression = []
    ) -> EyeBreakDecision {
        if let restEnd = restEndsAt {
            guard now >= restEnd else { return .none }
            restEndsAt = nil
            nextBreakAt = config.enabled ? now + config.interval : nil
            return .endRest
        }

        guard config.enabled else {
            nextBreakAt = nil
            return .none
        }

        guard let due = nextBreakAt else {
            nextBreakAt = now + config.interval
            return .none
        }

        guard now >= due else { return .none }

        guard suppression.isEmpty else {
            nextBreakAt = now + config.interval
            return .suppressed(suppression)
        }

        nextBreakAt = nil
        restEndsAt = now + config.restSeconds
        breakCount += 1
        return .beginRest
    }

    /// The next monotonic instant the monitor should wake for, if any.
    public func nextDeadline() -> TimeInterval? {
        if let restEndsAt { return restEndsAt }
        guard config.enabled else { return nil }
        return nextBreakAt
    }

    public mutating func reset() {
        nextBreakAt = nil
        restEndsAt = nil
        breakCount = 0
    }
}
