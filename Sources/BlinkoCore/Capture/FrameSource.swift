import Foundation
import CoreVideo

/// A single camera frame plus the monotonic timestamp at which it arrived.
///
/// The pixel buffer is only valid for the duration of the callback; nothing
/// downstream may retain it.
public struct VideoFrame {
    public let timestamp: TimeInterval
    public let pixelBuffer: CVPixelBuffer

    public init(timestamp: TimeInterval, pixelBuffer: CVPixelBuffer) {
        self.timestamp = timestamp
        self.pixelBuffer = pixelBuffer
    }
}

public enum FrameSourceError: Error, Equatable, CustomStringConvertible {
    case cameraUnavailable
    case permissionDenied
    case configurationFailed(String)
    case runtimeError(String)

    public var description: String {
        switch self {
        case .cameraUnavailable:
            return "No camera is available."
        case .permissionDenied:
            return "Camera access was denied."
        case let .configurationFailed(reason):
            return "Could not configure the camera: \(reason)"
        case let .runtimeError(reason):
            return "Camera error: \(reason)"
        }
    }
}

/// Injectable seam for camera frames (AVFoundation in production, fakes in tests).
public protocol FrameSource: AnyObject {
    var onFrame: ((VideoFrame) -> Void)? { get set }
    var onError: ((FrameSourceError) -> Void)? { get set }
    var isRunning: Bool { get }
    func start() throws
    func stop()
}

/// Injectable seam for landmark frames. The camera pipeline composes
/// `FrameSource` + `LandmarkExtractor`; replay reads a recorded CSV.
public protocol LandmarkFrameSource: AnyObject {
    var onFrame: ((FaceObservation) -> Void)? { get set }
    var onFinish: (() -> Void)? { get set }
    var isRunning: Bool { get }
    func start() throws
    func stop()
}
