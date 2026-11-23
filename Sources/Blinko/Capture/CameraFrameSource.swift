import Foundation
import AVFoundation
import CoreVideo
import BlinkoCore

/// AVFoundation-backed frame source.
///
/// Configured for the lowest preset Vision handles reliably, drops late frames,
/// and fully stops the session when `stop()` is called so the camera indicator
/// goes dark between bursts.
public final class CameraFrameSource: NSObject, FrameSource {
    public var onFrame: ((VideoFrame) -> Void)?
    public var onError: ((FrameSourceError) -> Void)?

    public var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "blinko.camera")
    private let stateLock = NSLock()
    private var running = false
    private var configured = false

    public override init() {
        super.init()
    }

    /// Requests camera access, delivering the result on the main queue.
    public static func requestCameraAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    public func start() throws {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw FrameSourceError.permissionDenied
        }

        try configureIfNeeded()

        stateLock.lock()
        running = true
        stateLock.unlock()

        captureQueue.async { [session] in
            if !session.isRunning {
                session.startRunning()
            }
        }
    }

    public func stop() {
        stateLock.lock()
        let wasRunning = running
        running = false
        stateLock.unlock()
        guard wasRunning else { return }

        captureQueue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    // MARK: - Configuration

    private func configureIfNeeded() throws {
        guard !configured else { return }

        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
        guard let device else {
            throw FrameSourceError.cameraUnavailable
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw FrameSourceError.configurationFailed(error.localizedDescription)
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // Lowest preset Vision still handles reliably (spec §4.1).
        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        } else if session.canSetSessionPreset(.medium) {
            session.sessionPreset = .medium
        }

        guard session.canAddInput(input) else {
            throw FrameSourceError.configurationFailed("camera input was rejected")
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        ]
        output.setSampleBufferDelegate(self, queue: captureQueue)

        guard session.canAddOutput(output) else {
            throw FrameSourceError.configurationFailed("video output was rejected")
        }
        session.addOutput(output)

        configured = true
    }
}

extension CameraFrameSource: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard isRunning,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        let frame = VideoFrame(
            timestamp: ProcessInfo.processInfo.systemUptime,
            pixelBuffer: pixelBuffer
        )
        onFrame?(frame)
    }
}
