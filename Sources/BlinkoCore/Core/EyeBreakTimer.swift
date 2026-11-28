import Foundation

/// Configuration for the camera-independent 20-20-20 eye-break timer.
public struct EyeBreakTimerConfig: Equatable {
    /// Whether automatic breaks are enabled.
    public var enabled: Bool
    /// Seconds between the end of one break and the start of the next.
    public var interval: TimeInterval
    /// How long the "look away" card stays up.
    public var restSeconds: TimeInterval
    /// Grace period after a rest ends before the focus timer may start again.
    /// Gives the user time to stand up and leave without arming the next break.
    public var returnDelay: TimeInterval
    /// How often the monitor re-checks for the user's return once the grace
    /// period has passed. Only used while the timer is waiting for presence.
    public var returnCheckSeconds: TimeInterval

    public init(
        enabled: Bool = true,
        interval: TimeInterval = 20 * 60,
        restSeconds: TimeInterval = 20,
        returnDelay: TimeInterval = 60,
        returnCheckSeconds: TimeInterval = 5
    ) {
        precondition(interval > 0, "interval must be positive")
        precondition(restSeconds > 0, "rest duration must be positive")
        precondition(returnDelay >= 0, "return delay must not be negative")
        precondition(returnCheckSeconds > 0, "return check must be positive")
        self.enabled = enabled
        self.interval = interval
        self.restSeconds = restSeconds
        self.returnDelay = returnDelay
        self.returnCheckSeconds = returnCheckSeconds
    }
}

/// What the caller should do after evaluating the timer.
public enum EyeBreakDecision: Equatable {
    case none
    case beginRest
    case endRest
    /// The user came back after a break, so a fresh focus interval started.
    case resumeFocus
    case suppressed(NudgeSuppression)
}

/// Pure, monotonic 20-20-20 timer.
///
/// One break is due every `interval` seconds and lasts `restSeconds`. The timer
/// owns no timers itself: the monitor arms a single tolerant one-shot timer at
/// `nextDeadline(after:)` and calls `evaluate` when it wakes. Time is monotonic
/// seconds supplied by the caller, so wall-clock jumps cannot delay or duplicate
/// a break (same rule as `BlinkGapPolicy`).
///
/// After a rest the focus timer does not simply restart: the user may have
/// walked away. The timer waits out `returnDelay` (so leaving does not arm a
/// break) and then starts a full fresh interval at the first moment presence is
/// reported. Time spent away is never credited, so a break can never fire while
/// the desk is empty.
public struct EyeBreakTimer {
    public private(set) var config: EyeBreakTimerConfig
    /// When the next automatic break is due, or nil while resting, waiting for
    /// the user to return, or disabled.
    public private(set) var nextBreakAt: TimeInterval?
    /// When the current rest ends, or nil when not resting.
    public private(set) var restEndsAt: TimeInterval?
    /// Earliest instant the focus timer may start again after a rest, or nil
    /// when not waiting for a return.
    public private(set) var resumeNotBefore: TimeInterval?
    /// Number of breaks started (automatic and manual).
    public private(set) var breakCount = 0

    public var isResting: Bool { restEndsAt != nil }
    /// True from the end of a rest until presence restarts the focus timer.
    public var isAwaitingReturn: Bool { resumeNotBefore != nil }

    public init(config: EyeBreakTimerConfig = EyeBreakTimerConfig()) {
        self.config = config
    }

    /// Starts (or restarts) the cadence. The first break is one full interval
    /// away, so enabling breaks never nags immediately.
    public mutating func start(at now: TimeInterval) {
        restEndsAt = nil
        resumeNotBefore = nil
        nextBreakAt = config.enabled ? now + config.interval : nil
    }

    public mutating func setEnabled(_ enabled: Bool, at now: TimeInterval) {
        guard config.enabled != enabled else { return }
        config.enabled = enabled
        if enabled {
            if restEndsAt == nil, resumeNotBefore == nil {
                nextBreakAt = now + config.interval
            }
        } else {
            nextBreakAt = nil
            restEndsAt = nil
            resumeNotBefore = nil
        }
    }

    /// Re-arms from `now` so a new interval takes effect immediately.
    public mutating func setInterval(_ interval: TimeInterval, at now: TimeInterval) {
        guard interval > 0, config.interval != interval else { return }
        config.interval = interval
        if config.enabled, restEndsAt == nil, resumeNotBefore == nil {
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
        resumeNotBefore = nil
        return .beginRest
    }

    /// Evaluates the timer at `now`.
    ///
    /// A break that comes due while suppressed is skipped and rescheduled a
    /// full interval later instead of firing late (no catch-up after sleep,
    /// quiet hours or pause).
    ///
    /// `presenceDetected` is the caller's return signal (camera face presence,
    /// or keyboard/mouse activity as an implicit fallback). It is only consulted
    /// once a rest has ended and the return grace period has elapsed.
    @discardableResult
    public mutating func evaluate(
        now: TimeInterval,
        suppression: NudgeSuppression = [],
        presenceDetected: Bool = false
    ) -> EyeBreakDecision {
        if let restEnd = restEndsAt {
            guard now >= restEnd else { return .none }
            restEndsAt = nil
            nextBreakAt = nil
            // Measured from the end of the rest, not from a late wake, so a
            // delayed evaluation never shortens the grace period.
            resumeNotBefore = restEnd + config.returnDelay
            return .endRest
        }

        if let resumeAt = resumeNotBefore {
            guard now >= resumeAt else { return .none }
            // Being away is exactly what this state is waiting for, so the idle
            // gate must not cancel the wait. Other suppression (quiet hours,
            // fullscreen, DND, low battery) keeps the old "skip and reschedule"
            // rule so the timer does not poll through a long quiet window.
            let blocking = suppression.subtracting(.userIdle)
            guard blocking.isEmpty else {
                resumeNotBefore = nil
                nextBreakAt = config.enabled ? now + config.interval : nil
                return .suppressed(blocking)
            }
            guard config.enabled else {
                resumeNotBefore = nil
                return .none
            }
            guard presenceDetected else { return .none }
            resumeNotBefore = nil
            nextBreakAt = now + config.interval
            return .resumeFocus
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
    ///
    /// While waiting for the user to return this is the end of the grace period
    /// and then a low-frequency re-check, so the monitor never polls faster than
    /// `returnCheckSeconds`.
    public func nextDeadline(after now: TimeInterval) -> TimeInterval? {
        if let restEndsAt { return restEndsAt }
        if let resumeNotBefore {
            return max(resumeNotBefore, now + config.returnCheckSeconds)
        }
        guard config.enabled else { return nil }
        return nextBreakAt
    }

    public mutating func reset() {
        nextBreakAt = nil
        restEndsAt = nil
        resumeNotBefore = nil
        breakCount = 0
    }
}
