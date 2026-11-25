import Foundation
import Vision
import BlinkoCore

/// Vision-backed landmark extraction. Largest face only, per spec §4.2.
///
/// Called from the pipeline's serial detection queue. A fresh request per frame
/// is still used (Vision request results are read-only and retain observations),
/// but all of its autoreleased temporaries are scoped to a local pool so they
/// do not accumulate between bursts.
public final class VisionLandmarkExtractor: LandmarkExtractor {
    public init() {}

    public func extract(from frame: VideoFrame) -> BlinkoCore.FaceObservation {
        // Vision allocates observations, landmark regions and intermediate
        // buffers per frame. A local pool releases them on this queue instead
        // of letting them accumulate until the dispatch worker drains.
        autoreleasepool {
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

            // Copy out only plain values: no Vision object outlives this pool.
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
    }

    private func area(of rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }
}
