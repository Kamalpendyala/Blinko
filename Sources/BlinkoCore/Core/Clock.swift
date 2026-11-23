import Foundation

/// Wall-clock and monotonic time behind one seam.
///
/// Core logic never calls `Date()` or `ProcessInfo` directly, so tests can
/// drive time deterministically with `FakeClock`.
public protocol Clock: AnyObject {
    /// Absolute wall-clock time. Used for quiet hours and daily aggregates.
    var now: Date { get }
    /// Monotonic seconds since boot. Used for scheduling and blink timing so
    /// wall-clock jumps cannot delay or duplicate work.
    var monotonicNow: TimeInterval { get }
}

public final class SystemClock: Clock {
    public init() {}

    public var now: Date { Date() }

    public var monotonicNow: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// Deterministic clock for tests. Wall-clock jumps can be simulated without
/// moving the monotonic clock, and vice versa.
public final class FakeClock: Clock {
    public private(set) var now: Date
    public private(set) var monotonicNow: TimeInterval

    public init(
        now: Date = Date(timeIntervalSince1970: 1_700_000_000),
        monotonicNow: TimeInterval = 1_000
    ) {
        self.now = now
        self.monotonicNow = monotonicNow
    }

    /// Advances both clocks together, as real time does.
    public func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
        monotonicNow += interval
    }

    /// Moves only the wall clock, simulating a manual clock change (SC-05/SC-06).
    public func setWallClock(_ date: Date) {
        now = date
    }

    /// Moves only the monotonic clock, simulating scheduler wakeups.
    public func advanceMonotonic(by interval: TimeInterval) {
        monotonicNow += interval
    }
}
