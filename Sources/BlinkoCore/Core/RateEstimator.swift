import Foundation

/// One completed sampling burst, already reduced to what the rate estimate needs.
///
/// Only aggregate values cross this boundary: a duration, valid-face seconds and
/// a blink count. No frames or landmark arrays are involved.
public struct BurstSummary: Equatable {
    public let startedAt: TimeInterval
    public let endedAt: TimeInterval
    public let validSeconds: Double
    public let blinkCount: Int

    public init(
        startedAt: TimeInterval,
        endedAt: TimeInterval,
        validSeconds: Double,
        blinkCount: Int
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.validSeconds = validSeconds.isFinite ? max(0, validSeconds) : 0
        self.blinkCount = max(0, blinkCount)
    }

    public var duration: TimeInterval { max(0, endedAt - startedAt) }

    /// Raw blinks per minute over valid-face time only (spec §4.5).
    public var ratePerMinute: Double {
        guard validSeconds > 0 else { return 0 }
        return Double(blinkCount) / validSeconds * 60
    }
}

public struct RateEstimatorConfig: Equatable {
    /// Bursts with less valid-face time than this are discarded (RE-03).
    public var minValidSeconds: Double
    /// EMA weight for the newest burst. 0.3 reacts within a few bursts without
    /// letting a single noisy burst dominate.
    public var smoothing: Double

    public init(minValidSeconds: Double = 3, smoothing: Double = 0.3) {
        precondition(minValidSeconds > 0, "minValidSeconds must be positive")
        precondition(smoothing > 0 && smoothing <= 1, "smoothing must be in (0, 1]")
        self.minValidSeconds = minValidSeconds
        self.smoothing = smoothing
    }
}

public struct RateUpdate: Equatable {
    public let accepted: Bool
    public let burstRate: Double?
    public let smoothedRate: Double?
}

/// Blinks per minute over valid-face seconds only, smoothed with an EMA across
/// bursts (spec §4.5, RE-01…04).
///
/// Invalid-face time is excluded from the denominator, and bursts that contain
/// too little valid face time are discarded entirely rather than producing a
/// wild estimate.
public final class RateEstimator {
    public let config: RateEstimatorConfig

    public private(set) var smoothedRate: Double?
    public private(set) var lastBurstRate: Double?
    public private(set) var acceptedBursts = 0
    public private(set) var discardedBursts = 0

    public init(config: RateEstimatorConfig = RateEstimatorConfig()) {
        self.config = config
    }

    @discardableResult
    public func ingest(_ burst: BurstSummary) -> RateUpdate {
        guard burst.validSeconds >= config.minValidSeconds else {
            discardedBursts += 1
            return RateUpdate(
                accepted: false,
                burstRate: nil,
                smoothedRate: smoothedRate
            )
        }

        let rate = burst.ratePerMinute
        lastBurstRate = rate

        if let current = smoothedRate {
            smoothedRate = current + config.smoothing * (rate - current)
        } else {
            smoothedRate = rate
        }

        acceptedBursts += 1
        return RateUpdate(accepted: true, burstRate: rate, smoothedRate: smoothedRate)
    }

    public func reset() {
        smoothedRate = nil
        lastBurstRate = nil
        acceptedBursts = 0
        discardedBursts = 0
    }
}
