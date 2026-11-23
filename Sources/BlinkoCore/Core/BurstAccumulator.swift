import Foundation

/// Accumulates one sampling burst from per-frame samples.
///
/// Valid-face seconds are measured from consecutive valid timestamps. Gaps are
/// capped at `maxGap` so a stalled camera or a dropped-face stretch cannot
/// inflate the denominator. Invalid frames break continuity and are never
/// counted as valid time.
public final class BurstAccumulator {
    public let maxGap: TimeInterval

    public private(set) var startedAt: TimeInterval?
    public private(set) var lastValidAt: TimeInterval?
    public private(set) var validSeconds: Double = 0
    public private(set) var blinkCount: Int = 0

    public init(maxGap: TimeInterval = 0.1) {
        precondition(maxGap > 0, "maxGap must be positive")
        self.maxGap = maxGap
    }

    public func begin(at timestamp: TimeInterval) {
        startedAt = timestamp
        lastValidAt = nil
        validSeconds = 0
        blinkCount = 0
    }

    public func record(_ sample: EyeSample) {
        guard sample.valid, sample.openness != nil else {
            lastValidAt = nil
            return
        }

        guard startedAt != nil else {
            begin(at: sample.timestamp)
            lastValidAt = sample.timestamp
            return
        }

        if let last = lastValidAt {
            validSeconds += min(max(0, sample.timestamp - last), maxGap)
        }
        lastValidAt = sample.timestamp
    }

    public func recordBlink() {
        blinkCount += 1
    }

    /// Ends the burst and resets the accumulator for the next one.
    public func finish(at timestamp: TimeInterval) -> BurstSummary? {
        guard let startedAt else { return nil }
        let summary = BurstSummary(
            startedAt: startedAt,
            endedAt: timestamp,
            validSeconds: validSeconds,
            blinkCount: blinkCount
        )
        reset()
        return summary
    }

    public func reset() {
        startedAt = nil
        lastValidAt = nil
        validSeconds = 0
        blinkCount = 0
    }
}
