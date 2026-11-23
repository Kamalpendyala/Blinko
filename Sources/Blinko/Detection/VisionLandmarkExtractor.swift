import Foundation
import Vision
import BlinkoCore

/// Vision-backed landmark extraction. Largest face only, per spec §4.2.
///
/// Called from the pipeline's serial detection queue, so a fresh request per
/// frame is safe. Per-frame allocation is intentional for Phase A clarity;
/// Phase C can switch to a reusable sequence handler if measurements demand it.
public final class VisionLandmarkExtractor: LandmarkExtractor {
    public init() {}

    public func extract(from frame: VideoFrame) -> BlinkoCore.FaceObservation {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(
            cvPixelBuffer: frame.pixelBuffer,
            orientation: .up,
            options: [:]
        )

        do {
            try handler.perform([request])
        } catch {
            return BlinkoCore.FaceObservation.noFace(timestamp: frame.timestamp)
        }

        guard let faces = request.results, !faces.isEmpty else {
            return BlinkoCore.FaceObservation.noFace(timestamp: frame.timestamp)
        }

        let face = faces.max { lhs, rhs in
            area(of: lhs.boundingBox) < area(of: rhs.boundingBox)
        }!

        let box = face.boundingBox

        func imagePoints(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            guard let region else { return [] }
            return region.normalizedPoints.map { point in
                CGPoint(
                    x: box.origin.x + CGFloat(point.x) * box.width,
                    y: box.origin.y + CGFloat(point.y) * box.height
                )
            }
        }

        return BlinkoCore.FaceObservation(
            timestamp: frame.timestamp,
            faceFound: true,
            leftEye: imagePoints(face.landmarks?.leftEye),
            rightEye: imagePoints(face.landmarks?.rightEye),
            faceBoundingBox: box,
            yaw: face.yaw?.doubleValue,
            roll: face.roll?.doubleValue
        )
    }

    private func area(of rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }
}
