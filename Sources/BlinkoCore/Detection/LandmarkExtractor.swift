import Foundation

/// Injectable seam for Vision (or a fake in tests).
///
/// Implementations must be single-threaded: the detection pipeline calls this
/// from one serial queue.
public protocol LandmarkExtractor: AnyObject {
    func extract(from frame: VideoFrame) -> FaceObservation
}
