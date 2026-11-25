import Foundation

/// Everything that can make a sampling burst ineligible (spec §5) or suppress
/// a reminder (spec §6). The monitor fills this from the injectable seams; the
/// gate is pure so it can be tested without a camera, battery or workspace.
public struct BurstConditions: Equatable {
    public var isPaused: Bool
    public var cameraDenied: Bool
    public var isAsleep: Bool
    public var isScreenLocked: Bool
    public var isFullscreen: Bool
    public var isDoNotDisturb: Bool
    public var isScreenSharing: Bool
    public var quietHoursActive: Bool
    /// Seconds since the last keyboard/mouse event, when known.
    public var secondsSinceInput: Double?
    public var idleThreshold: Double
    /// Battery charge in 0…1, or nil on a desktop Mac.
    public var batteryLevel: Double?
    public var isPluggedIn: Bool
    /// Below this fraction, unplugged Macs skip bursts (SC-08).
    public var lowBatteryThreshold: Double

    public init(
        isPaused: Bool = false,
        cameraDenied: Bool = false,
        isAsleep: Bool = false,
        isScreenLocked: Bool = false,
        isFullscreen: Bool = false,
        isDoNotDisturb: Bool = false,
        isScreenSharing: Bool = false,
        quietHoursActive: Bool = false,
        secondsSinceInput: Double? = nil,
        idleThreshold: Double = 300,
        batteryLevel: Double? = nil,
        isPluggedIn: Bool = true,
        lowBatteryThreshold: Double = 0.20
    ) {
        self.isPaused = isPaused
        self.cameraDenied = cameraDenied
        self.isAsleep = isAsleep
        self.isScreenLocked = isScreenLocked
        self.isFullscreen = isFullscreen
        self.isDoNotDisturb = isDoNotDisturb
        self.isScreenSharing = isScreenSharing
        self.quietHoursActive = quietHoursActive
        self.secondsSinceInput = secondsSinceInput
        self.idleThreshold = idleThreshold
        self.batteryLevel = batteryLevel
        self.isPluggedIn = isPluggedIn
        self.lowBatteryThreshold = lowBatteryThreshold
    }
}

/// Maps system conditions onto the existing `NudgeSuppression` flags so the
/// same decision stops bursts, stops reminders and is visible in the debug UI.
public struct BurstGate {
    public init() {}

    public func suppression(for conditions: BurstConditions) -> NudgeSuppression {
        var suppression: NudgeSuppression = []

        if conditions.isPaused { suppression.insert(.paused) }
        if conditions.cameraDenied { suppression.insert(.cameraUnavailable) }
        if conditions.isAsleep { suppression.insert(.asleep) }
        if conditions.isScreenLocked { suppression.insert(.screenLocked) }
        if conditions.isFullscreen { suppression.insert(.fullscreen) }
        if conditions.isDoNotDisturb { suppression.insert(.doNotDisturb) }
        if conditions.isScreenSharing { suppression.insert(.screenSharing) }
        if conditions.quietHoursActive { suppression.insert(.quietHours) }

        if let idle = conditions.secondsSinceInput,
           idle.isFinite,
           conditions.idleThreshold > 0,
           idle >= conditions.idleThreshold {
            suppression.insert(.userIdle)
        }

        if let level = conditions.batteryLevel,
           level.isFinite,
           level < conditions.lowBatteryThreshold,
           !conditions.isPluggedIn {
            suppression.insert(.lowBattery)
        }

        return suppression
    }

    /// A burst may run only when nothing is suppressing it.
    public func canRunBurst(_ conditions: BurstConditions) -> Bool {
        suppression(for: conditions).isEmpty
    }
}
