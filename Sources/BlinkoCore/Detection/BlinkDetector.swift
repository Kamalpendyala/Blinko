import Foundation

public struct BlinkDetectorConfig: Equatable {
    /// A frame is closed when openness falls below baseline × closedRatio.
    public var closedRatio: Double
    /// It is open again when openness rises above baseline × openRatio.
    /// The gap between the two thresholds is the hysteresis band.
    public var openRatio: Double
    /// Minimum number of consecutive observed closed frames.
    public var minClosedFrames: Int
    /// Maximum closure duration; longer closures are eyes shut / looking down.
    public var maxBlinkDuration: TimeInterval
    /// Rolling baseline window in valid frames (~3 s at 30 fps).
    public var baselineWindow: Int
    /// Valid frames needed before automatic baseline estimation starts.
    public var minBaselineSamples: Int

    public init(
        closedRatio: Double = 0.65,
        openRatio: Double = 0.80,
        minClosedFrames: Int = 2,
        maxBlinkDuration: TimeInterval = 0.400,
        baselineWindow: Int = 90,
        minBaselineSamples: Int = 15
    ) {
        precondition(closedRatio < openRatio, "hysteresis requires closedRatio < openRatio")
        precondition(baselineWindow >= minBaselineSamples)
        self.closedRatio = closedRatio
        self.openRatio = openRatio
        self.minClosedFrames = minClosedFrames
        self.maxBlinkDuration = maxBlinkDuration
        self.baselineWindow = baselineWindow
        self.minBaselineSamples = minBaselineSamples
    }
}

public enum DetectorPhase: Equatable {
    case calibrating
    case open
    case closed
}

public struct BlinkEvent: Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let peakClosedness: Double

    public init(start: TimeInterval, end: TimeInterval, peakClosedness: Double) {
        self.start = start
        self.end = end
        self.peakClosedness = peakClosedness
    }

    public var duration: TimeInterval { max(0, end - start) }
}

/// Immutable snapshot of detector state for one sample, used by the debug UI.
public struct DetectorSample: Equatable {
    public let timestamp: TimeInterval
    public let openness: Double?
    public let valid: Bool
    public let baseline: Double?
    public let closedThreshold: Double?
    public let openThreshold: Double?
    public let phase: DetectorPhase

    public init(
        timestamp: TimeInterval,
        openness: Double?,
        valid: Bool,
        baseline: Double?,
        closedThreshold: Double?,
        openThreshold: Double?,
        phase: DetectorPhase
    ) {
        self.timestamp = timestamp
        self.openness = openness
        self.valid = valid
        self.baseline = baseline
        self.closedThreshold = closedThreshold
        self.openThreshold = openThreshold
        self.phase = phase
    }
}

/// Pure blink state machine over `(timestamp, openness, valid)` samples.
///
/// Rules (spec §4.4):
/// - baseline is a rolling median of valid samples taken while the eye is open;
/// - closed below `baseline × 0.65`, open above `baseline × 0.80` (hysteresis);
/// - a blink is ≥ 2 consecutive closed frames lasting ≤ 400 ms, then re-open;
/// - invalid frames abort any in-flight closure and never count as closure;
/// - out-of-order or duplicate timestamps are ignored.
public final class BlinkDetector {
    public let config: BlinkDetectorConfig

    public private(set) var baseline: Double?
    public private(set) var blinkCount = 0
    /// Number of open→closed transitions, including ones that were not blinks.
    public private(set) var closureEpisodeCount = 0
    public private(set) var phase: DetectorPhase = .calibrating

    /// Called synchronously on the thread that calls `process(_:)`.
    public var onBlink: ((BlinkEvent) -> Void)?

    private var closeStart: TimeInterval = 0
    private var closedFrameCount = 0
    private var peakClosedness: Double = 0
    private var lastTimestamp: TimeInterval = -.infinity
    private var baselineSamples: [Double] = []

    public init(config: BlinkDetectorConfig = BlinkDetectorConfig()) {
        self.config = config
    }

    public var closedThreshold: Double? { baseline.map { $0 * config.closedRatio } }
    public var openThreshold: Double? { baseline.map { $0 * config.openRatio } }
    public var isCalibrated: Bool { baseline != nil }

    /// Seeds the baseline from a ~5 s calibration recording.
    public func calibrate(with opennessSamples: [Double]) {
        let clean = opennessSamples.filter { $0.isFinite && $0 >= 0 }
        guard !clean.isEmpty else { return }
        baselineSamples = Array(clean.suffix(config.baselineWindow))
        baseline = Self.median(baselineSamples)
        phase = .open
        closedFrameCount = 0
        closeStart = 0
        peakClosedness = 0
    }

    public func reset() {
        baseline = nil
        baselineSamples.removeAll()
        blinkCount = 0
        closureEpisodeCount = 0
        phase = .calibrating
        closedFrameCount = 0
        closeStart = 0
        peakClosedness = 0
        lastTimestamp = -.infinity
    }

    @discardableResult
    public func process(_ sample: EyeSample) -> BlinkEvent? {
        // BD-09: duplicates and out-of-order samples are ignored safely.
        guard sample.timestamp > lastTimestamp else { return nil }
        lastTimestamp = sample.timestamp

        // BD-06: invalid frames pause the machine and discard in-flight closures.
        guard sample.valid, let openness = sample.openness, openness.isFinite else {
            phase = baseline == nil ? .calibrating : .open
            closedFrameCount = 0
            closeStart = 0
            return nil
        }

        if phase != .closed {
            updateBaseline(with: openness)
            if baseline != nil, phase == .calibrating {
                phase = .open
            }
        }

        guard let closedThreshold, let openThreshold else {
            return nil
        }

        var event: BlinkEvent?

        switch phase {
        case .calibrating:
            break

        case .open:
            if openness < closedThreshold {
                phase = .closed
                closureEpisodeCount += 1
                closeStart = sample.timestamp
                closedFrameCount = 1
                peakClosedness = closeness(of: openness)
            }

        case .closed:
            // Values inside the hysteresis band hold the current phase (BD-05).
            if openness > openThreshold {
                // The re-opening frame ends the closure; it is not itself a
                // closed frame, so it must not satisfy the frame-count rule.
                let duration = sample.timestamp - closeStart
                phase = .open
                if closedFrameCount >= config.minClosedFrames, duration <= config.maxBlinkDuration {
                    blinkCount += 1
                    event = BlinkEvent(
                        start: closeStart,
                        end: sample.timestamp,
                        peakClosedness: peakClosedness
                    )
                }
                closedFrameCount = 0
                closeStart = 0
            } else {
                closedFrameCount += 1
                peakClosedness = max(peakClosedness, closeness(of: openness))
            }
        }

        if let event {
            onBlink?(event)
        }
        return event
    }

    private func updateBaseline(with openness: Double) {
        baselineSamples.append(openness)
        if baselineSamples.count > config.baselineWindow {
            baselineSamples.removeFirst(baselineSamples.count - config.baselineWindow)
        }
        guard baselineSamples.count >= config.minBaselineSamples else { return }
        baseline = Self.median(baselineSamples)
    }

    private func closeness(of openness: Double) -> Double {
        guard let baseline, baseline > 0 else { return 0 }
        return min(1, max(0, 1 - openness / baseline))
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
