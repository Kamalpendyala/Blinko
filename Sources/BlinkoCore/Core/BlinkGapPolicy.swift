import Foundation

/// Configuration for the no-blink watchdog.
public struct BlinkGapPolicyConfig: Equatable {
    /// How long the face may go without a blink before a reminder fires.
    public var interval: TimeInterval

    public init(interval: TimeInterval = 5) {
        precondition(interval > 0, "interval must be positive")
        self.interval = interval
    }
}

/// Fires a reminder whenever no blink has been seen for `interval` seconds.
///
/// Unlike `NudgePolicy` this is a simple watchdog: while the user keeps their
/// eyes open it re-arms every `interval`, so the reminder repeats for as long
/// as blinking stops. A blink restarts the countdown immediately.
public final class BlinkGapPolicy {
    public private(set) var config: BlinkGapPolicyConfig

    public private(set) var nudgeCount = 0
    public private(set) var lastBlinkAt: TimeInterval?

    private var nextDue: TimeInterval?

    public init(config: BlinkGapPolicyConfig = BlinkGapPolicyConfig()) {
        self.config = config
    }

    /// Changes the interval and re-arms from the last blink so the new value
    /// takes effect without waiting for another heartbeat.
    public func setInterval(_ interval: TimeInterval, at now: TimeInterval) {
        guard interval > 0 else { return }
        config.interval = interval
        nextDue = (lastBlinkAt ?? now) + interval
    }

    /// Starts the countdown, e.g. when monitoring begins or resumes.
    public func start(at now: TimeInterval) {
        lastBlinkAt = now
        nextDue = now + config.interval
    }

    /// A blink was detected; the next reminder is a full interval away.
    public func recordBlink(at now: TimeInterval) {
        lastBlinkAt = now
        nextDue = now + config.interval
    }

    public func secondsSinceBlink(at now: TimeInterval) -> TimeInterval? {
        guard let lastBlinkAt else { return nil }
        return max(0, now - lastBlinkAt)
    }

    /// Evaluates the watchdog. Call at a steady pace (the monitor uses 2 Hz).
    @discardableResult
    public func evaluate(
        now: TimeInterval,
        facePresent: Bool,
        suppression: NudgeSuppression = []
    ) -> NudgeDecision {
        guard suppression.isEmpty else {
            // Paused / quiet hours / etc. restart the countdown so ending the
            // suppression does not immediately fire a stale reminder.
            nextDue = now + config.interval
            return .suppressed(suppression)
        }

        guard facePresent else {
            // Looking away is not "not blinking"; start fresh when the face
            // comes back.
            lastBlinkAt = now
            nextDue = now + config.interval
            return .none
        }

        guard let due = nextDue else {
            nextDue = now + config.interval
            return .none
        }

        guard now >= due else { return .none }

        nextDue = now + config.interval
        nudgeCount += 1
        return .nudge(.noBlink)
    }

    public func reset() {
        lastBlinkAt = nil
        nextDue = nil
        nudgeCount = 0
    }
}
