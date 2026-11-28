import Foundation
import BlinkoCore

protocol DetectionPipelineDelegate: AnyObject {
    func detectionPipeline(
        _ pipeline: DetectionPipeline,
        didProduce sample: EyeSample,
        detector: DetectorSample
    )
    func detectionPipeline(_ pipeline: DetectionPipeline, didDetect blink: BlinkEvent)
    func detectionPipeline(_ pipeline: DetectionPipeline, didFail error: FrameSourceError)
    func detectionPipelineDidFinishReplay(_ pipeline: DetectionPipeline)
}

/// Composes frame capture, landmark extraction, eye metrics and the blink
/// state machine. All heavy work runs on one serial queue; UI callbacks are
/// delivered on the main queue.
///
/// While the detector is busy, incoming camera frames are dropped rather than
/// queued, so detection always works on the newest frame.
final class DetectionPipeline {
    weak var delegate: DetectionPipelineDelegate?

    let detector: BlinkDetector

    private let metrics: EyeMetrics
    private let extractor: LandmarkExtractor
    private let processingQueue = DispatchQueue(label: "blinko.detection")
    private var camera: CameraFrameSource?
    private var replay: ReplayFrameSource?
    private let recorder: LandmarkCSVRecorder?

    private let busyLock = NSLock()
    private var busy = false

    /// Frames arrive at the camera rate; SwiftUI only needs ~30 Hz. Batching the
    /// main-queue hand-off avoids one dispatch block per frame without dropping
    /// samples from the detector or the debug plot.
    private struct Delivery {
        let sample: EyeSample
        let detector: DetectorSample
        let blink: BlinkEvent?
    }

    private let deliveryLock = NSLock()
    private var pendingDeliveries: [Delivery] = []
    private var deliveryWork: DispatchWorkItem?
    private let deliveryInterval: TimeInterval = 1.0 / 30.0

    init(
        extractor: LandmarkExtractor = VisionLandmarkExtractor(),
        metrics: EyeMetrics = EyeMetrics(),
        detector: BlinkDetector = BlinkDetector(),
        recorder: LandmarkCSVRecorder? = nil
    ) {
        self.extractor = extractor
        self.metrics = metrics
        self.detector = detector
        self.recorder = recorder
    }

    // MARK: - Lifecycle

    func startCamera() {
        stopReplay()

        let camera: CameraFrameSource
        if let existing = self.camera {
            // Reuse the configured AVCaptureSession across duty-cycle bursts:
            // `stopCamera()` stopped it, so the indicator is dark in between.
            camera = existing
        } else {
            let created = CameraFrameSource()
            created.onError = { [weak self] error in
                self?.publish(error)
            }
            created.onFrame = { [weak self] frame in
                self?.enqueue(frame)
            }
            self.camera = created
            camera = created
        }

        do {
            try camera.start()
        } catch {
            publish(error as? FrameSourceError ?? .runtimeError(error.localizedDescription))
        }
    }

    /// Stops capture but keeps the configured session for the next burst.
    func stopCamera() {
        camera?.stop()
        clearBusy()
    }

    /// Burst-end stop: halts delivery, drains the final batch while the burst
    /// is still open, then tears the session down. Waiting for `stopRunning()`
    /// before the drain would stall the main thread for the whole camera
    /// teardown, so the drain barrier runs first.
    func stopCameraAndDrain() {
        assert(Thread.isMainThread)
        camera?.stopDelivering()
        drainPendingDeliveries()
        camera?.finishStopping()
        clearBusy()
    }

    private func clearBusy() {
        busyLock.lock()
        busy = false
        busyLock.unlock()
    }

    /// Drops the configured session so the next burst reconfigures the camera.
    /// Used after a device-level failure (unplugged/unavailable camera).
    func resetCamera() {
        stopCamera()
        camera = nil
    }

    private func stopReplay() {
        replay?.stop()
        replay = nil
    }

    func startReplay(url: URL, pace: Bool = true) {
        stopCamera()
        stopReplay()

        do {
            let replay = try ReplayFrameSource(contentsOf: url, pace: pace)
            replay.onFrame = { [weak self] observation in
                guard let self else { return }
                // Synchronous so replay completion (and the headless summary)
                // cannot overtake frame processing.
                self.processingQueue.sync {
                    self.handle(observation)
                }
            }
            replay.onFinish = { [weak self] in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.delegate?.detectionPipelineDidFinishReplay(self)
                }
            }
            self.replay = replay
            try replay.start()
        } catch {
            publish(.runtimeError("Replay failed: \(error)"))
        }
    }

    /// Stops all sources but keeps the camera session configured for reuse.
    func stop() {
        stopCamera()
        stopReplay()
    }

    /// Waits for every frame already in flight and delivers the rest of the
    /// batch synchronously. Called at burst end, before the monitor closes its
    /// burst, so no sample or blink is lost to the 30 Hz hand-off.
    func drainPendingDeliveries() {
        assert(Thread.isMainThread)
        camera?.waitForCallbacks()
        processingQueue.sync { }
        flushDeliveries()
    }

    func shutdown() {
        stopReplay()
        if Thread.isMainThread {
            stopCameraAndDrain()
        } else {
            stopCamera()
        }
        camera = nil
        recorder?.close()
    }

    // MARK: - Frame handling

    private func enqueue(_ frame: VideoFrame) {
        busyLock.lock()
        if busy {
            busyLock.unlock()
            return
        }
        busy = true
        busyLock.unlock()

        processingQueue.async { [weak self] in
            guard let self else { return }
            autoreleasepool {
                let observation = self.extractor.extract(from: frame)
                self.handle(observation)
            }
            self.busyLock.lock()
            self.busy = false
            self.busyLock.unlock()
        }
    }

    private func handle(_ observation: FaceObservation) {
        recorder?.append(observation)

        let sample = metrics.evaluate(observation)
        let event = detector.process(sample)
        let snapshot = DetectorSample(
            timestamp: sample.timestamp,
            openness: sample.openness,
            valid: sample.valid,
            baseline: detector.baseline,
            closedThreshold: detector.closedThreshold,
            openThreshold: detector.openThreshold,
            phase: detector.phase
        )

        deliveryLock.lock()
        pendingDeliveries.append(Delivery(sample: sample, detector: snapshot, blink: event))
        let shouldSchedule = deliveryWork == nil
        var work: DispatchWorkItem?
        if shouldSchedule {
            let item = DispatchWorkItem { [weak self] in
                self?.flushDeliveries()
            }
            deliveryWork = item
            work = item
        }
        deliveryLock.unlock()

        if let work {
            DispatchQueue.main.asyncAfter(deadline: .now() + deliveryInterval, execute: work)
        }
    }

    /// Drains all samples accumulated since the previous hand-off in one main
    /// queue block, preserving sample-then-blink order. Cancel the pending timer
    /// so a stale batch cannot drain a later burst's deliveries early.
    private func flushDeliveries() {
        deliveryLock.lock()
        let batch = pendingDeliveries
        pendingDeliveries.removeAll(keepingCapacity: true)
        let work = deliveryWork
        deliveryWork = nil
        deliveryLock.unlock()
        work?.cancel()

        for delivery in batch {
            delegate?.detectionPipeline(self, didProduce: delivery.sample, detector: delivery.detector)
            if let blink = delivery.blink {
                delegate?.detectionPipeline(self, didDetect: blink)
            }
        }
    }

    private func publish(_ error: FrameSourceError) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.detectionPipeline(self, didFail: error)
        }
    }
}
