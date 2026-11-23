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
    public static func opennessRatio(of points: [CGPoint]) -> Double? {
        guard points.count >= 3,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            return nil
        }

        let xs = points.map { Double($0.x) }
        let ys = points.map { Double($0.y) }
        guard let minX = xs.min(),
              let maxX = xs.max(),
              let minY = ys.min(),
              let maxY = ys.max() else {
            return nil
        }

        let width = maxX - minX
        guard width.isFinite, width > 0 else { return nil }

        var height = maxY - minY

        // Split the non-corner points into top and bottom halves.
        let leftIndex = xs.firstIndex(of: minX)!
        let rightIndex = xs.firstIndex(of: maxX)!
        let interior = points.enumerated()
            .filter { $0.offset != leftIndex && $0.offset != rightIndex }
            .map(\.element)

        if interior.count >= 2 {
            let sorted = interior.sorted { $0.y < $1.y }
            let half = sorted.count / 2
            let bottom = sorted.prefix(half)
            let top = sorted.suffix(sorted.count - half)
            if !bottom.isEmpty, !top.isEmpty {
                let bottomMean = bottom.reduce(0.0) { $0 + Double($1.y) } / Double(bottom.count)
                let topMean = top.reduce(0.0) { $0 + Double($1.y) } / Double(top.count)
                height = topMean - bottomMean
            }
        }

        guard height.isFinite, height >= 0 else { return nil }
        let ratio = height / width
        return ratio.isFinite ? ratio : nil
    }

    static func horizontalSpan(of points: [CGPoint]) -> Double {
        let xs = points.map { Double($0.x) }
        guard let minX = xs.min(), let maxX = xs.max() else { return 0 }
        return maxX - minX
    }
}
