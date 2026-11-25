import Foundation

public struct CalibrationResult: Equatable {
    public let baseline: Double?
    public let sampleCount: Int

    public init(baseline: Double?, sampleCount: Int) {
        self.baseline = baseline
        self.sampleCount = sampleCount
    }

    public var isValid: Bool { baseline != nil }
}

/// Collects open-eye openness samples during the guided ~5 s calibration.
///
/// The baseline is the median of the collected samples, matching the detector's
/// rolling-median estimator (spec §4.4). A run with too few valid face frames
/// is rejected rather than seeding a bad baseline.
public final class CalibrationCollector {
    public let minSamples: Int
    public let maxSamples: Int

    public private(set) var samples: [Double] = []

    public init(minSamples: Int = 15, maxSamples: Int = 300) {
        precondition(minSamples > 0, "minSamples must be positive")
        precondition(maxSamples >= minSamples, "maxSamples must be at least minSamples")
        self.minSamples = minSamples
        self.maxSamples = maxSamples
    }

    public var sampleCount: Int { samples.count }

    public func add(openness: Double) {
        // Only plausible open-eye ratios are useful; closed/partial frames and
        // out-of-range values would bias the median toward a bad baseline.
        guard (0.01...1.0).contains(openness) else { return }
        samples.append(openness)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    public func finish() -> CalibrationResult {
        guard samples.count >= minSamples else {
            return CalibrationResult(baseline: nil, sampleCount: samples.count)
        }
        return CalibrationResult(baseline: Self.median(samples), sampleCount: samples.count)
    }

    public func reset() {
        samples.removeAll(keepingCapacity: true)
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
