import Foundation

/// Conditions that suppress reminders. The policy treats any non-empty set as a
/// hard "do not nudge", and resets the low-rate streak so resuming does not
/// immediately fire based on stale bursts.
public struct NudgeSuppression: OptionSet, Equatable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let paused = NudgeSuppression(rawValue: 1 << 0)
    public static let quietHours = NudgeSuppression(rawValue: 1 << 1)
    public static let fullscreen = NudgeSuppression(rawValue: 1 << 2)
    public static let doNotDisturb = NudgeSuppression(rawValue: 1 << 3)
    public static let screenSharing = NudgeSuppression(rawValue: 1 << 4)
    public static let cameraUnavailable = NudgeSuppression(rawValue: 1 << 5)
    public static let lowBattery = NudgeSuppression(rawValue: 1 << 6)
    public static let userIdle = NudgeSuppression(rawValue: 1 << 7)
    public static let screenLocked = NudgeSuppression(rawValue: 1 << 8)
    public static let asleep = NudgeSuppression(rawValue: 1 << 9)
}

public enum NudgeReason: Equatable {
    /// No blink for the configured gap (the active Phase B trigger).
    case noBlink
    /// Smoothed blink rate stayed below the threshold (retained for Phase C).
    case lowRate
    /// The camera-independent 20-20-20 break timer.
    case eyeBreak
}

public enum NudgeDecision: Equatable {
    case none
    case nudge(NudgeReason)
    case suppressed(NudgeSuppression)
    case cooldown
    case hourlyLimit
    case noRate
}

public struct NudgePolicyConfig: Equatable {
    /// Smoothed rate below which a burst counts as "low" (spec §6).
    public var lowRateThreshold: Double
    /// Consecutive low bursts required before a nudge.
    public var lowBurstsRequired: Int
    /// Minimum time between nudges.
    public var cooldown: TimeInterval
    /// Maximum nudges inside `hourWindow`.
    public var maxNudgesPerHour: Int
    public var hourWindow: TimeInterval

    public init(
        lowRateThreshold: Double = 8,
        lowBurstsRequired: Int = 3,
        cooldown: TimeInterval = 10 * 60,
        maxNudgesPerHour: Int = 3,
        hourWindow: TimeInterval = 60 * 60
    ) {
        precondition(lowRateThreshold > 0)
        precondition(lowBurstsRequired > 0)
        precondition(cooldown >= 0)
        precondition(maxNudgesPerHour > 0)
        precondition(hourWindow > 0)
        self.lowRateThreshold = lowRateThreshold
        self.lowBurstsRequired = lowBurstsRequired
        self.cooldown = cooldown
        self.maxNudgesPerHour = maxNudgesPerHour
        self.hourWindow = hourWindow
    }
}

/// Pure reminder policy (spec §6, NP-01…07).
///
/// Time is monotonic seconds supplied by the caller, so wall-clock jumps cannot
/// delay or duplicate a reminder.
public final class NudgePolicy {
    public let config: NudgePolicyConfig

    public private(set) var lowStreak = 0
    public private(set) var nudgeCount = 0
    public private(set) var lastNudgeAt: TimeInterval?

    private var nudgeTimestamps: [TimeInterval] = []

    public init(config: NudgePolicyConfig = NudgePolicyConfig()) {
        self.config = config
    }

    /// Evaluates one accepted burst.
    @discardableResult
    public func evaluate(
        rate: Double?,
        now: TimeInterval,
        suppression: NudgeSuppression = []
    ) -> NudgeDecision {
        guard suppression.isEmpty else {
            lowStreak = 0
            return .suppressed(suppression)
        }

        guard let rate, rate.isFinite else { return .noRate }

        if rate >= config.lowRateThreshold {
            lowStreak = 0
            return .none
        }

        lowStreak += 1
        guard lowStreak >= config.lowBurstsRequired else { return .none }

        nudgeTimestamps.removeAll { now - $0 >= config.hourWindow }

        if let lastNudgeAt, now - lastNudgeAt < config.cooldown {
            return .cooldown
        }

        guard nudgeTimestamps.count < config.maxNudgesPerHour else {
            return .hourlyLimit
        }

        lastNudgeAt = now
        nudgeTimestamps.append(now)
        nudgeCount += 1
        return .nudge(.lowRate)
    }

    public func resetLowStreak() {
        lowStreak = 0
    }

    public func reset() {
        lowStreak = 0
        nudgeCount = 0
        lastNudgeAt = nil
        nudgeTimestamps.removeAll()
    }
}
