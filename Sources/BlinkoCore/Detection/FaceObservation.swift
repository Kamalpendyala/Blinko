import Foundation
import CoreGraphics

/// One face observed in one frame, already reduced to what detection needs.
///
/// Eye contours use image-normalized coordinates (0…1, origin bottom-left),
/// matching Vision's convention after conversion out of face-box space.
/// This is derived data only: no pixels are retained.
public struct FaceObservation: Equatable {
    public var timestamp: TimeInterval
    public var faceFound: Bool
    public var leftEye: [CGPoint]
    public var rightEye: [CGPoint]
    public var faceBoundingBox: CGRect
    /// Yaw in radians, when Vision provides it.
    public var yaw: Double?
    /// Roll in radians, when Vision provides it.
    public var roll: Double?

    public init(
        timestamp: TimeInterval,
        faceFound: Bool,
        leftEye: [CGPoint] = [],
        rightEye: [CGPoint] = [],
        faceBoundingBox: CGRect = .zero,
        yaw: Double? = nil,
        roll: Double? = nil
    ) {
        self.timestamp = timestamp
        self.faceFound = faceFound
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.faceBoundingBox = faceBoundingBox
        self.yaw = yaw
        self.roll = roll
    }

    public static func noFace(timestamp: TimeInterval) -> FaceObservation {
        FaceObservation(timestamp: timestamp, faceFound: false)
    }

    /// A face was found and both eye contours are present.
    public var hasEyeContours: Bool {
        faceFound && leftEye.count >= 3 && rightEye.count >= 3
    }
}
