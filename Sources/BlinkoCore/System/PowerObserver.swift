import Foundation

public enum PowerEvent: Equatable {
    case willSleep
    case didWake
    case screenLocked
    case screenUnlocked
    case screensDidSleep
    case screensDidWake
    case sessionBecameActive
    case sessionResignedActive
}

/// Injectable seam for sleep/wake/lock notifications (NSWorkspace in production).
public protocol PowerObserver: AnyObject {
    var onEvent: ((PowerEvent) -> Void)? { get set }
    func start()
    func stop()
}
