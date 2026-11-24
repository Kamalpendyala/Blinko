import Foundation

/// Duty-cycle configuration (spec §5): a short sampling burst, then a long
/// gap with the camera fully stopped.
public struct SamplingSchedulerConfig: Equatable {
    /// How long each sampling burst lasts.
    public var burstSeconds: TimeInterval
    /// Start-to-start cadence. Must be at least `burstSeconds`.
    public var intervalSeconds: TimeInterval
    /// A tick later than this is treated as a missed cycle and dropped instead
    /// of firing a burst. Keeps a stalled runloop or a missed wake notification
    /// from producing catch-up bursts.
    public var lateGraceSeconds: TimeInterval
    /// Sleep longer than this restarts the cadence and resets stale state.
    public var restartAfterSeconds: TimeInterval
    /// When a burst is due but the machine is ineligible (idle, low battery,
    /// fullscreen…), retry after this long rather than waiting a full interval.
    public var retrySeconds: TimeInterval

    public init(
        burstSeconds: TimeInterval = 12,
        intervalSeconds: TimeInterval = 60,
        lateGraceSeconds: TimeInterval = 5 * 60,
        restartAfterSeconds: TimeInterval = 5 * 60,
        retrySeconds: TimeInterval = 30
    ) {
        precondition(burstSeconds > 0, "burstSeconds must be positive")
        precondition(intervalSeconds >= burstSeconds, "interval must cover the burst")
        precondition(lateGraceSeconds > 0, "lateGraceSeconds must be positive")
        precondition(restartAfterSeconds > 0, "restartAfterSeconds must be positive")
        precondition(retrySeconds > 0, "retrySeconds must be positive")
        self.burstSeconds = burstSeconds
        self.intervalSeconds = intervalSeconds
        self.lateGraceSeconds = lateGraceSeconds
        self.restartAfterSeconds = restartAfterSeconds
        self.retrySeconds = retrySeconds
    }
}

public enum SchedulerAction: Equatable {
    case startBurst
    case endBurst
    case none
}

public enum WakeOutcome: Equatable {
    /// Short gap: keep the cadence, but wait a full interval before the next burst.
    case resumed
    /// Long gap: stale rate/streak state should be discarded.
    case restarted
}

/// Absolute-timestamp duty-cycle scheduler (spec §5, SC-01…07).
///
/// All times are monotonic seconds supplied by the caller. The scheduler never
/// uses wall-clock time or countdowns, so clock changes cannot delay, duplicate
/// or flood bursts. Each call to `action(at:allowed:)` advances at most one
/// step, which makes a late tick safe to replay.
public final class SamplingScheduler {
    public private(set) var config: SamplingSchedulerConfig

    public private(set) var isSuspended = false
    public private(set) var isBursting = false
    public private(set) var nextBurstAt: TimeInterval?
    public private(set) var burstEndsAt: TimeInterval?
    public private(set) var burstStartedAt: TimeInterval?

    public private(set) var startedBursts = 0
    public private(set) var skippedOverdue = 0
    public private(set) var deniedTicks = 0

    public init(config: SamplingSchedulerConfig = SamplingSchedulerConfig()) {
        self.config = config
    }

    public var isIdle: Bool {
        !isBursting && nextBurstAt == nil
    }

    /// Starts the cadence. `immediateBurst` is used on launch/resume so the
    /// first sample arrives without waiting a full minute.
    public func start(at now: TimeInterval, immediateBurst: Bool = true) {
        isSuspended = false
        isBursting = false
        burstEndsAt = nil
        burstStartedAt = nil
        nextBurstAt = immediateBurst ? now : now + config.intervalSeconds
        startedBursts = 0
        skippedOverdue = 0
        deniedTicks = 0
    }

    public func stop() {
        isSuspended = false
        isBursting = false
        burstEndsAt = nil
        burstStartedAt = nil
        nextBurstAt = nil
    }

    /// Advances the state machine at the given instant.
    ///
    /// `allowed` is the gate decision (paused, idle, low battery, fullscreen,
    /// quiet hours…). A denied tick reschedules a short retry instead of firing
    /// a burst, so the camera stays off while the machine is ineligible.
    public func action(at now: TimeInterval, allowed: Bool = true) -> SchedulerAction {
        guard !isSuspended else { return .none }

        if isBursting {
            guard let endsAt = burstEndsAt, now >= endsAt else { return .none }
            let startedAt = burstStartedAt ?? (endsAt - config.burstSeconds)
            isBursting = false
            burstEndsAt = nil
            burstStartedAt = nil
            // The next burst is one interval after this burst started, not
            // after it ended, so a slow camera start cannot stretch the cadence.
            nextBurstAt = startedAt + config.intervalSeconds
            return .endBurst
        }

        guard let due = nextBurstAt, now >= due else { return .none }

        if now - due > config.lateGraceSeconds {
            // Missed while asleep or stalled: drop the overdue burst and wait
            // for the next normal slot (SC-02).
            skippedOverdue += 1
            nextBurstAt = now + config.intervalSeconds
            return .none
        }

        guard allowed else {
            deniedTicks += 1
            nextBurstAt = now + config.retrySeconds
            return .none
        }

        isBursting = true
        burstStartedAt = now
        burstEndsAt = now + config.burstSeconds
        nextBurstAt = nil
        startedBursts += 1
        return .startBurst
    }

    /// The instant the caller should wake to call `action(at:)` again.
    public func nextDeadline(after now: TimeInterval) -> TimeInterval? {
        guard !isSuspended else { return nil }
        if isBursting { return burstEndsAt }
        guard let due = nextBurstAt else { return nil }
        return max(due, now + 0.05)
    }

    /// Abandons a burst in progress but keeps the scheduler active, with the
    /// next burst a full interval away. Used when the gate turns against us
    /// (quiet hours, camera loss) so a later retry can resume sampling.
    public func abortBurst(at now: TimeInterval) {
        guard isBursting else { return }
        isBursting = false
        burstEndsAt = nil
        burstStartedAt = nil
        nextBurstAt = now + config.intervalSeconds
    }

    /// Suspends the cadence, e.g. on screen lock, display sleep or system sleep.
    /// A burst in progress is abandoned; no partial summary is produced.
    public func suspend(at now: TimeInterval) {
        isSuspended = true
        isBursting = false
        burstEndsAt = nil
        burstStartedAt = nil
        nextBurstAt = nil
    }

    /// Resumes after a lock/unlock cycle with a fresh, full interval.
    public func resume(at now: TimeInterval) {
        isSuspended = false
        isBursting = false
        burstEndsAt = nil
        burstStartedAt = nil
        nextBurstAt = now + config.intervalSeconds
    }

    /// Handles wake-from-sleep. Overdue bursts are always dropped; the caller
    /// uses the outcome to decide whether to reset the low-rate streak.
    @discardableResult
    public func handleWake(at now: TimeInterval, asleepFor duration: TimeInterval) -> WakeOutcome {
        isSuspended = false
        isBursting = false
        burstEndsAt = nil
        burstStartedAt = nil
        nextBurstAt = now + config.intervalSeconds
        return duration > config.restartAfterSeconds ? .restarted : .resumed
    }

    /// Requests an out-of-band burst (menu "Sample Now"). The next `action`
    /// call starts it immediately.
    public func forceBurst(at now: TimeInterval) {
        guard !isSuspended, !isBursting else { return }
        nextBurstAt = now
    }

    public func setInterval(_ seconds: TimeInterval, at now: TimeInterval) {
        guard seconds >= config.burstSeconds else { return }
        config.intervalSeconds = seconds
        if !isBursting, !isSuspended {
            nextBurstAt = now + seconds
        }
    }

    public func setBurstSeconds(_ seconds: TimeInterval, at now: TimeInterval) {
        guard seconds > 0, seconds <= config.intervalSeconds else { return }
        config.burstSeconds = seconds
        if isBursting, let startedAt = burstStartedAt {
            burstEndsAt = max(now, startedAt + seconds)
        }
    }
}
