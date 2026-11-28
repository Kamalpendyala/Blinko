import Foundation

/// Decides whether the user is at the machine after an eye break.
///
/// The camera is the primary signal: a face seen within `faceWindow` seconds of
/// the last valid sample counts as present. Keyboard/mouse activity is the
/// implicit fallback for when the camera is denied, covered, unavailable, or no
/// face can be detected — it is always on, never a setting.
///
/// Kept pure and value-typed so the fallback rule is unit-testable and the
/// monitor stays a thin adapter over the camera and `IdleMonitor` seams.
public struct ReturnPresence: Equatable {
    /// How long a camera face sample keeps counting as "still here".
    public var faceWindow: TimeInterval
    /// How recently the user must have typed or moved the mouse.
    public var inputWindow: TimeInterval

    public init(faceWindow: TimeInterval = 2, inputWindow: TimeInterval = 6) {
        precondition(faceWindow >= 0, "face window must not be negative")
        precondition(inputWindow >= 0, "input window must not be negative")
        self.faceWindow = faceWindow
        self.inputWindow = inputWindow
    }

    /// - Parameters:
    ///   - now: Monotonic seconds.
    ///   - lastValidFaceAt: Timestamp of the last valid camera face sample.
    ///   - secondsSinceInput: Idle time from the keyboard/mouse seam, or nil
    ///     when the platform cannot report it.
    public func isPresent(
        now: TimeInterval,
        lastValidFaceAt: TimeInterval?,
        secondsSinceInput: TimeInterval?
    ) -> Bool {
        if let lastFace = lastValidFaceAt, now - lastFace <= faceWindow {
            return true
        }
        if let idle = secondsSinceInput, idle <= inputWindow {
            return true
        }
        return false
    }
}
