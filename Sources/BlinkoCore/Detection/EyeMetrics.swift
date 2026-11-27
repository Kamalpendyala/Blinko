import Foundation
import CoreGraphics

public enum EyeSampleInvalidReason: String, Equatable, Sendable {
    case noFace
    case faceTooSmall
    case faceRotated
    case missingEye
    case asymmetricEyes
    case degenerateLandmarks
}

/// One frame reduced to an openness measurement.
///
/// `openness` is the mean eye-openness ratio of both eyes (vertical extent
/// divided by horizontal span). Invalid frames carry no value and must never
/// be treated as closure by the blink detector.
public struct EyeSample: Equatable {
    public let timestamp: TimeInterval
    public let openness: Double?
    public let valid: Bool
    public let reason: EyeSampleInvalidReason?
    public let leftRatio: Double?
    public let rightRatio: Double?

    public init(
        timestamp: TimeInterval,
        openness: Double?,
        valid: Bool,
        reason: EyeSampleInvalidReason? = nil,
        leftRatio: Double? = nil,
        rightRatio: Double? = nil
    ) {
        self.timestamp = timestamp
        self.openness = openness
        self.valid = valid
        self.reason = reason
        self.leftRatio = leftRatio
        self.rightRatio = rightRatio
    }

    public static func invalid(timestamp: TimeInterval, reason: EyeSampleInvalidReason) -> EyeSample {
        EyeSample(timestamp: timestamp, openness: nil, valid: false, reason: reason)
    }
}

public struct EyeMetricsConfig: Equatable {
    /// Minimum normalized face-box area (width × height) before we trust landmarks.
    public var minFaceArea: Double
    /// Minimum normalized eye width; smaller contours are degenerate.
    public var minEyeWidth: Double
    /// Maximum absolute yaw in radians.
    public var maxYaw: Double
    /// Maximum absolute roll in radians.
    public var maxRoll: Double
    /// Maximum relative left/right difference before the frame is rejected.
    public var maxAsymmetry: Double

    public init(
        minFaceArea: Double = 0.02,
        minEyeWidth: Double = 0.005,
        maxYaw: Double = 25 * .pi / 180,
        maxRoll: Double = 30 * .pi / 180,
        maxAsymmetry: Double = 0.5
    ) {
        self.minFaceArea = minFaceArea
        self.minEyeWidth = minEyeWidth
        self.maxYaw = maxYaw
        self.maxRoll = maxRoll
        self.maxAsymmetry = maxAsymmetry
    }
}

/// Turns `FaceObservation` landmarks into a validity-checked openness ratio.
///
/// The generic ratio is the classic 6-point EAR adapted to any point count:
/// the leftmost and rightmost points define the corners; the remaining points
/// are split into top and bottom groups and their mean vertical separation is
/// divided by the corner-to-corner width. With six points this is algebraically
/// identical to the textbook EAR formula.
public struct EyeMetrics {
    public let config: EyeMetricsConfig

    public init(config: EyeMetricsConfig = EyeMetricsConfig()) {
        self.config = config
    }

    public func evaluate(_ observation: FaceObservation) -> EyeSample {
        let timestamp = observation.timestamp

        guard observation.faceFound else {
            return .invalid(timestamp: timestamp, reason: .noFace)
        }

        let box = observation.faceBoundingBox
        let faceArea = Double(box.width * box.height)
        guard faceArea.isFinite, faceArea >= config.minFaceArea else {
            return .invalid(timestamp: timestamp, reason: .faceTooSmall)
        }

        if let yaw = observation.yaw, !yaw.isFinite || abs(yaw) > config.maxYaw {
            return .invalid(timestamp: timestamp, reason: .faceRotated)
        }
        if let roll = observation.roll, !roll.isFinite || abs(roll) > config.maxRoll {
            return .invalid(timestamp: timestamp, reason: .faceRotated)
        }

        // A single visible eye is not enough: winking and occlusion must not
        // be counted as blinks, so the frame is flagged invalid (EM-04).
        guard observation.leftEye.count >= 3, observation.rightEye.count >= 3 else {
            return .invalid(timestamp: timestamp, reason: .missingEye)
        }

        guard Self.horizontalSpan(of: observation.leftEye) >= config.minEyeWidth,
              Self.horizontalSpan(of: observation.rightEye) >= config.minEyeWidth else {
            return .invalid(timestamp: timestamp, reason: .degenerateLandmarks)
        }

        guard let left = Self.opennessRatio(of: observation.leftEye),
              let right = Self.opennessRatio(of: observation.rightEye) else {
            return .invalid(timestamp: timestamp, reason: .degenerateLandmarks)
        }

        let strongest = max(left, right)
        if strongest > 1e-9, abs(left - right) / strongest > config.maxAsymmetry {
            return .invalid(timestamp: timestamp, reason: .asymmetricEyes)
        }

        let openness = (left + right) / 2
        guard openness.isFinite else {
            return .invalid(timestamp: timestamp, reason: .degenerateLandmarks)
        }

        return EyeSample(
            timestamp: timestamp,
            openness: openness,
            valid: true,
            reason: nil,
            leftRatio: left,
            rightRatio: right
        )
    }

    /// Eye-openness ratio for one contour, or `nil` when the contour is degenerate.
    ///
    /// This runs twice per frame, so it avoids the four intermediate arrays the
    /// naive implementation would allocate: extrema and corner indices are found
    /// in one pass, and only the interior y-values are buffered for sorting.
    public static func opennessRatio(of points: [CGPoint]) -> Double? {
        guard points.count >= 3 else { return nil }

        var minX = Double.infinity
        var maxX = -Double.infinity
        var minY = Double.infinity
        var maxY = -Double.infinity
        var leftIndex = 0
        var rightIndex = 0

        for (index, point) in points.enumerated() {
            let x = Double(point.x)
            let y = Double(point.y)
            guard x.isFinite, y.isFinite else { return nil }
            // Strict comparisons keep the first point at an extrema, matching
            // the old `firstIndex(of:)` semantics for duplicate corner values.
            if x < minX { minX = x; leftIndex = index }
            if x > maxX { maxX = x; rightIndex = index }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }

        let width = maxX - minX
        guard width.isFinite, width > 0 else { return nil }

        var height = maxY - minY
        var interiorY = [Double]()
        interiorY.reserveCapacity(points.count - 2)
        for (index, point) in points.enumerated() where index != leftIndex && index != rightIndex {
            interiorY.append(Double(point.y))
        }

        if interiorY.count >= 2 {
            interiorY.sort()
            let half = interiorY.count / 2
            let bottomMean = interiorY.prefix(half).reduce(0.0) { $0 + $1 } / Double(half)
            let topCount = interiorY.count - half
            let topMean = interiorY.suffix(topCount).reduce(0.0) { $0 + $1 } / Double(topCount)
            height = topMean - bottomMean
        }

        guard height.isFinite, height >= 0 else { return nil }
        let ratio = height / width
        return ratio.isFinite ? ratio : nil
    }

    static func horizontalSpan(of points: [CGPoint]) -> Double {
        guard let first = points.first else { return 0 }
        var minX = Double(first.x)
        var maxX = minX
        for point in points.dropFirst() {
            let x = Double(point.x)
            if x < minX { minX = x }
            if x > maxX { maxX = x }
        }
        return maxX - minX
    }
}
