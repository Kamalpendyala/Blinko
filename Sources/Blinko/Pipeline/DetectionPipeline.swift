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
        stop()

        let camera = CameraFrameSource()
        camera.onError = { [weak self] error in
            self?.publish(error)
        }
        camera.onFrame = { [weak self] frame in
            self?.enqueue(frame)
        }
        self.camera = camera

        do {
            try camera.start()
        } catch {
            publish(error as? FrameSourceError ?? .runtimeError(error.localizedDescription))
        }
    }

    func startReplay(url: URL, pace: Bool = true) {
        stop()

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

    func stop() {
        camera?.stop()
        camera = nil
        replay?.stop()
        replay = nil
        busyLock.lock()
        busy = false
        busyLock.unlock()
    }

    func shutdown() {
        stop()
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
            let observation = self.extractor.extract(from: frame)
            self.handle(observation)
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

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.detectionPipeline(self, didProduce: sample, detector: snapshot)
            if let event {
                self.delegate?.detectionPipeline(self, didDetect: event)
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
