import Foundation
import BlinkoCore

/// Everything the menu bar and debug window need to display, published at a
/// human pace rather than once per camera frame.
struct MonitorSnapshot: Equatable {
    var isRunning: Bool
    var isPaused: Bool
    var cameraDenied: Bool
    var fallbackEnabled: Bool
    var quietHoursActive: Bool
    var smoothedRate: Double?
    var lastBurstRate: Double?
    var lowStreak: Int
    var lowBurstsRequired: Int
    var nudgeCount: Int
    var status: String
}

/// Owns the live camera pipeline and turns it into rate estimates and nudges.
///
/// Phase B runs the camera continuously and slices the stream into
/// `settings.burstSeconds` windows. Phase C will replace the continuous stream
/// with a duty-cycled scheduler; the rate/nudge logic here does not change.
final class BlinkMonitor {
    var onSnapshot: ((MonitorSnapshot) -> Void)?
    var onSample: ((EyeSample, DetectorSample) -> Void)?
    var onBlink: ((BlinkEvent) -> Void)?
    var onNudge: ((NudgeReason) -> Void)?
    var onError: ((FrameSourceError) -> Void)?

    private(set) var settings: Settings
    private(set) var isRunning = false
    private(set) var isPaused = false
    private(set) var cameraDenied = false

    private let clock: Clock
    private let rateEstimator = RateEstimator()
    private let nudgePolicy = NudgePolicy()
    private let burst = BurstAccumulator()

    private var pipeline: DetectionPipeline?
    private var recorder: LandmarkCSVRecorder?
    private var heartbeatTimer: Timer?
    private var status = "Starting…"
    private var lastSnapshot: MonitorSnapshot?

    init(clock: Clock = SystemClock(), settings: Settings = Settings()) {
        self.clock = clock
        self.settings = settings
    }

    // MARK: - Lifecycle

    func start(recorder: LandmarkCSVRecorder? = nil) {
        assert(Thread.isMainThread)
        guard !isRunning else { return }

        self.recorder = recorder
        isRunning = true
        isPaused = false
        cameraDenied = false
        rateEstimator.reset()
        nudgePolicy.reset()
        burst.reset()

        startHeartbeat()
        requestCamera()
    }

    func stop() {
        assert(Thread.isMainThread)
        guard isRunning else { return }

        isRunning = false
        isPaused = false
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        if let pipeline {
            pipeline.shutdown()
        } else {
            recorder?.close()
        }
        pipeline = nil
        recorder = nil
        burst.reset()
        nudgePolicy.stopFallback()
        publish()
    }

    /// One-click pause: camera off, no reminders, low-streak cleared.
    func pause() {
        assert(Thread.isMainThread)
        guard isRunning, !isPaused else { return }

        isPaused = true
        pipeline?.stop()
        pipeline = nil
        burst.reset()
        nudgePolicy.resetLowStreak()
        nudgePolicy.stopFallback()
        setStatus("Paused — camera off, no reminders.")
        publish()
    }

    func resume() {
        assert(Thread.isMainThread)
        guard isRunning, isPaused else { return }

        isPaused = false
        rateEstimator.reset()
        nudgePolicy.resetLowStreak()
        burst.reset()

        if cameraDenied {
            if settings.fallbackRemindersEnabled {
                nudgePolicy.beginFallback(at: clock.monotonicNow)
                setStatus("Camera unavailable — timed reminders on.")
            } else {
                setStatus("Camera access denied. Enable timed reminders from the menu.")
            }
            publish()
            return
        }

        requestCamera()
    }

    func retryCamera() {
        assert(Thread.isMainThread)
        guard isRunning, !isPaused else { return }

        cameraDenied = false
        nudgePolicy.stopFallback()
        requestCamera()
    }

    func setFallbackRemindersEnabled(_ enabled: Bool) {
        assert(Thread.isMainThread)
        settings.fallbackRemindersEnabled = enabled

        if enabled, cameraDenied, !isPaused {
            nudgePolicy.beginFallback(at: clock.monotonicNow)
        } else if !enabled {
            nudgePolicy.stopFallback()
        }
        publish()
    }

    func setSoundEnabled(_ enabled: Bool) {
        assert(Thread.isMainThread)
        settings.soundEnabled = enabled
        publish()
    }

    /// Swaps the landmark recorder without touching the rate/nudge state.
    func setRecorder(_ recorder: LandmarkCSVRecorder?) {
        assert(Thread.isMainThread)
        guard isRunning, !isPaused, !cameraDenied else {
            if self.recorder !== recorder {
                self.recorder?.close()
            }
            self.recorder = recorder
            return
        }

        // `shutdown()` closes the previous recorder before the new one starts.
        pipeline?.shutdown()
        pipeline = nil
        self.recorder = recorder
        startPipeline()
    }

    // MARK: - Camera

    private func requestCamera() {
        setStatus("Requesting camera access…")
        CameraFrameSource.requestCameraAccess { [weak self] granted in
            guard let self, self.isRunning, !self.isPaused else { return }

            if granted {
                self.cameraDenied = false
                self.startPipeline()
            } else {
                self.handleCameraUnavailable()
            }
        }
    }

    private func startPipeline() {
        let pipeline = DetectionPipeline(recorder: recorder)
        pipeline.delegate = self
        self.pipeline = pipeline
        burst.begin(at: clock.monotonicNow)
        pipeline.startCamera()
        setStatus("Monitoring — camera on.")
        publish()
    }

    private func handleCameraUnavailable(
        status message: String = "Camera access denied. Enable Blinko in System Settings › Privacy & Security › Camera."
    ) {
        cameraDenied = true
        pipeline?.stop()
        pipeline = nil
        burst.reset()
        nudgePolicy.stopFallback()
        if settings.fallbackRemindersEnabled {
            nudgePolicy.beginFallback(at: clock.monotonicNow)
        }
        setStatus(message)
        publish()
    }

    // MARK: - Detection input

    private func ingest(sample: EyeSample, detector: DetectorSample) {
        guard isRunning, !isPaused else { return }

        onSample?(sample, detector)

        if burst.startedAt == nil {
            burst.begin(at: sample.timestamp)
        }
        burst.record(sample)

        if let start = burst.startedAt, sample.timestamp - start >= settings.burstSeconds {
            finishBurst(at: sample.timestamp)
        }
    }

    private func ingest(blink: BlinkEvent) {
        guard isRunning, !isPaused else { return }
        burst.recordBlink()
        onBlink?(blink)
    }

    private func finishBurst(at now: TimeInterval) {
        guard let summary = burst.finish(at: now) else { return }
        burst.begin(at: now)

        let update = rateEstimator.ingest(summary)
        guard update.accepted, let smoothed = update.smoothedRate else {
            publish()
            return
        }

        let decision = nudgePolicy.evaluate(
            rate: smoothed,
            now: now,
            suppression: currentSuppression(includeCameraUnavailable: false)
        )
        if case let .nudge(reason) = decision {
            deliverNudge(reason)
        }
        publish()
    }

    // MARK: - Heartbeat (fallback + quiet-hours/menu refresh)

    private func startHeartbeat() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.heartbeat()
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    private func heartbeat() {
        guard isRunning else { return }

        if cameraDenied, settings.fallbackRemindersEnabled, !isPaused {
            let decision = nudgePolicy.evaluateFallback(
                now: clock.monotonicNow,
                enabled: true,
                cameraUnavailable: true,
                suppression: currentSuppression(includeCameraUnavailable: false)
            )
            if case let .nudge(reason) = decision {
                deliverNudge(reason)
            }
        }

        publishIfChanged()
    }

    // MARK: - Nudges

    private func deliverNudge(_ reason: NudgeReason) {
        switch reason {
        case .lowRate:
            setStatus("Nudged: blink rate stayed low.")
        case .timedFallback:
            setStatus("Nudged: timed reminder.")
        }
        onNudge?(reason)
        publish()
    }

    private func currentSuppression(includeCameraUnavailable: Bool) -> NudgeSuppression {
        var suppression: NudgeSuppression = []
        if isPaused { suppression.insert(.paused) }
        if settings.quietHours.isActive(at: clock.now) { suppression.insert(.quietHours) }
        if includeCameraUnavailable && cameraDenied { suppression.insert(.cameraUnavailable) }
        return suppression
    }

    // MARK: - Snapshot

    private func setStatus(_ text: String) {
        status = text
    }

    private func makeSnapshot() -> MonitorSnapshot {
        MonitorSnapshot(
            isRunning: isRunning,
            isPaused: isPaused,
            cameraDenied: cameraDenied,
            fallbackEnabled: settings.fallbackRemindersEnabled,
            quietHoursActive: settings.quietHours.isActive(at: clock.now),
            smoothedRate: rateEstimator.smoothedRate,
            lastBurstRate: rateEstimator.lastBurstRate,
            lowStreak: nudgePolicy.lowStreak,
            lowBurstsRequired: nudgePolicy.config.lowBurstsRequired,
            nudgeCount: nudgePolicy.nudgeCount,
            status: status
        )
    }

    private func publish() {
        let snapshot = makeSnapshot()
        lastSnapshot = snapshot
        onSnapshot?(snapshot)
    }

    private func publishIfChanged() {
        let snapshot = makeSnapshot()
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        onSnapshot?(snapshot)
    }
}

extension BlinkMonitor: DetectionPipelineDelegate {
    func detectionPipeline(
        _ pipeline: DetectionPipeline,
        didProduce sample: EyeSample,
        detector: DetectorSample
    ) {
        ingest(sample: sample, detector: detector)
    }

    func detectionPipeline(_ pipeline: DetectionPipeline, didDetect blink: BlinkEvent) {
        ingest(blink: blink)
    }

    func detectionPipeline(_ pipeline: DetectionPipeline, didFail error: FrameSourceError) {
        // Ignore late errors from a pipeline that has already been stopped.
        guard isRunning else { return }

        onError?(error)

        switch error {
        case .permissionDenied:
            handleCameraUnavailable()
        case .cameraUnavailable:
            handleCameraUnavailable(status: "No camera is available.")
        case .configurationFailed, .runtimeError:
            setStatus(error.description)
            publish()
        }
    }

    func detectionPipelineDidFinishReplay(_ pipeline: DetectionPipeline) {
        // The monitor never runs replay; AppDelegate owns that pipeline.
    }
}
