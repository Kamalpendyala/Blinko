import Foundation

/// Injectable seam for keyboard/mouse idleness (SC-09). The production
/// implementation reads CoreGraphics event timestamps; tests return fixed values.
public protocol IdleMonitor: AnyObject {
    /// Seconds since the last keyboard or mouse event, or nil when unknown.
    var secondsSinceLastInput: TimeInterval? { get }
}

/// Injectable seam for battery state (SC-08).
public protocol BatteryMonitor: AnyObject {
    /// Charge fraction in 0…1, or nil when there is no battery (desktop Mac).
    var level: Double? { get }
    /// True while running from AC power.
    var isPluggedIn: Bool { get }
}

/// Fullscreen / Focus / screen-sharing state (spec §6 suppression).
public struct PresenceState: Equatable {
    public var isFullscreen: Bool
    public var isDoNotDisturb: Bool
    public var isScreenSharing: Bool

    public init(
        isFullscreen: Bool = false,
        isDoNotDisturb: Bool = false,
        isScreenSharing: Bool = false
    ) {
        self.isFullscreen = isFullscreen
        self.isDoNotDisturb = isDoNotDisturb
        self.isScreenSharing = isScreenSharing
    }
}

/// Injectable seam for presentation-state suppression. Kept separate from
/// `PowerObserver` so the monitor can poll it cheaply around bursts.
public protocol PresenceMonitor: AnyObject {
    var current: PresenceState { get }
}
