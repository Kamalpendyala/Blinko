import Foundation
import BlinkoCore

/// Everything the menu bar and debug window need to display, published at a
/// human pace rather than once per camera frame.
struct MonitorSnapshot: Equatable {
    var isRunning: Bool
    var isPaused: Bool
    var cameraDenied: Bool
    var quietHoursEnabled: Bool
    var quietHoursActive: Bool
    var facePresent: Bool
    var secondsSinceBlink: Double?
    var noBlinkInterval: Double
    var autoDismissSeconds: Double
    var smoothedRate: Double?
    var lastBurstRate: Double?
    var lowStreak: Int
    var lowBurstsRequired: Int
    var nudgeCount: Int
    var status: String

    // Phase C: duty-cycle state. Times are monotonic seconds.
    var isBursting: Bool
    var nextBurstAt: TimeInterval?
    var burstEndsAt: TimeInterval?
    var burstSeconds: Double
    var intervalSeconds: Double
    var suppression: NudgeSuppression

    // Phase E: camera-independent 20-20-20 breaks.
    var eyeBreaksEnabled: Bool
    var eyeBreakIntervalSeconds: Double
    var eyeBreakRestSeconds: Double
    var nextEyeBreakAt: TimeInterval?
    var isEyeBreaking: Bool
}

/// State of the guided calibration flow shown in Settings.
enum CalibrationState: Equatable {
    case idle
    case collecting(progress: Double)
    case completed(baseline: Double)
    case failed(String)
}

extension NudgeSuppression {
    /// Short human-readable cause for the menu bar and debug window.
    var shortDescription: String? {
        if contains(.paused) { return "paused" }
        if contains(.cameraUnavailable) { return "camera unavailable" }
        if contains(.asleep) { return "asleep" }
        if contains(.screenLocked) { return "screen locked" }
        if contains(.userIdle) { return "idle" }
        if contains(.lowBattery) { return "low battery" }
        if contains(.fullscreen) { return "fullscreen" }
        if contains(.screenSharing) { return "screen sharing" }
        if contains(.doNotDisturb) { return "do not disturb" }
        if contains(.quietHours) { return "quiet hours" }
        return nil
    }
}

/// Owns the live camera pipeline, the duty-cycle scheduler and the reminder
/// policies.
///
/// Phase C samples in short bursts (default 12 s every 60 s) and fully stops the
/// capture session in between, so the camera indicator is dark for most of the
/// time (spec §5). A one-shot timer with tolerance wakes the app at the next
/// absolute deadline; there is no per-second polling between bursts.
final class BlinkMonitor {
    var onSnapshot: ((MonitorSnapshot) -> Void)?
    var onSample: ((EyeSample, DetectorSample) -> Void)?
    var onBlink: ((BlinkEvent) -> Void)?
    var onNudge: ((NudgeReason) -> Void)?
    var onError: ((FrameSourceError) -> Void)?
    /// Called when the system suspends sampling (sleep, lock, session switch).
    var onSystemSuspend: (() -> Void)?
    /// Called when a 20-20-20 card should be hidden: its rest ended normally,
    /// or the cadence was abandoned (pause, stop, system suspend, disabled).
    /// Lets the presenter avoid owning a second timer for the same interval.
    var onEyeBreakCardEnded: (() -> Void)?
    /// Called whenever a setting changes, so the app can persist it.
    var onSettingsChanged: ((Settings) -> Void)?
    /// Called after a completed burst with aggregate-only values.
    var onBurstCompleted: ((BurstSummary) -> Void)?
    /// Progress/completion of the guided calibration flow.
    var onCalibrationState: ((CalibrationState) -> Void)?

    private(set) var settings: Settings
    private(set) var isRunning = false
    private(set) var isPaused = false
    private(set) var cameraDenied = false

    private let clock: Clock
    private let powerObserver: PowerObserver
    private let idleMonitor: IdleMonitor
    private let batteryMonitor: BatteryMonitor
    private let presenceMonitor: PresenceMonitor
    private let activity = BurstActivity()
    private let burstGate = BurstGate()

    private let rateEstimator = RateEstimator()
    private let nudgePolicy = NudgePolicy()
    private let burst = BurstAccumulator()
    private let gapPolicy: BlinkGapPolicy
    private var eyeBreakTimer: EyeBreakTimer
    private var scheduler: SamplingScheduler

    private var pipeline: DetectionPipeline?
    private var recorder: LandmarkCSVRecorder?
    private var scheduleTimer: Timer?
    private var heartbeatTimer: Timer?
    private var eyeBreakWakeTimer: Timer?

    private var status = "Starting…"
    private var lastSnapshot: MonitorSnapshot?
    private var lastValidFaceAt: TimeInterval?
    private var deliveredNudgeCount = 0

    private var isAsleep = false
    private var areScreensAsleep = false
    private var isScreenLocked = false
    private var isSessionActive = true
    private var sleepStartedAt: TimeInterval?

    private var cachedPresence = PresenceState()
    private var presenceCheckedAt: TimeInterval = -.infinity

    // Guided calibration: collect ~5 s of open-eye openness, then seed the
    // detector baseline with the median.
    private let calibrationDuration: TimeInterval = 5
    private var calibrationCollector: CalibrationCollector?
    private var calibrationStartedAt: TimeInterval?
    private var calibrationTimer: Timer?

    init(
        clock: Clock = SystemClock(),
        settings: Settings = Settings(),
        powerObserver: PowerObserver = SystemPowerObserver(),
        idleMonitor: IdleMonitor = SystemIdleMonitor(),
        batteryMonitor: BatteryMonitor = SystemBatteryMonitor(),
        presenceMonitor: PresenceMonitor = SystemPresenceMonitor()
    ) {
        self.clock = clock
        self.settings = settings
        self.powerObserver = powerObserver
        self.idleMonitor = idleMonitor
        self.batteryMonitor = batteryMonitor
        self.presenceMonitor = presenceMonitor
        self.gapPolicy = BlinkGapPolicy(
            config: BlinkGapPolicyConfig(interval: settings.noBlinkInterval)
        )
        self.eyeBreakTimer = EyeBreakTimer(
            config: EyeBreakTimerConfig(
                enabled: settings.eyeBreaksEnabled,
                interval: settings.eyeBreakIntervalSeconds,
                restSeconds: settings.eyeBreakRestSeconds
            )
        )
        self.scheduler = SamplingScheduler(
            config: SamplingSchedulerConfig(
                burstSeconds: settings.burstSeconds,
                intervalSeconds: settings.intervalSeconds
            )
        )
    }

    // MARK: - Lifecycle

    func start(recorder: LandmarkCSVRecorder? = nil) {
        assert(Thread.isMainThread)
        guard !isRunning else { return }

        self.recorder = recorder
        isRunning = true
        isPaused = settings.paused
        cameraDenied = false
        deliveredNudgeCount = 0
        rateEstimator.reset()
        nudgePolicy.reset()
        burst.reset()
        gapPolicy.reset()
        lastValidFaceAt = nil
        isAsleep = false
        areScreensAsleep = false
        isScreenLocked = false
        isSessionActive = true
        sleepStartedAt = nil
        cachedPresence = PresenceState()
        presenceCheckedAt = -.infinity
        activity.end()
        cancelTimers()
        resetCalibrationState(notify: false)
        eyeBreakTimer.reset()
        eyeBreakTimer.start(at: clock.monotonicNow)
        scheduleEyeBreakEvaluation()

        scheduler = SamplingScheduler(
            config: SamplingSchedulerConfig(
                burstSeconds: settings.burstSeconds,
                intervalSeconds: settings.intervalSeconds
            )
        )
        scheduler.start(at: clock.monotonicNow, immediateBurst: true)

        powerObserver.onEvent = { [weak self] event in
            self?.handle(powerEvent: event)
        }
        powerObserver.start()

        guard !isPaused else {
            setStatus("Paused — camera off, no reminders.")
            publish()
            return
        }

        setStatus("Requesting camera access…")
        publish()
        requestCamera()
    }

    func stop() {
        assert(Thread.isMainThread)
        guard isRunning else { return }

        isRunning = false
        isPaused = false
        cancelTimers()
        resetCalibrationState(notify: false)
        stopCurrentBurst()
        scheduler.stop()
        powerObserver.stop()
        powerObserver.onEvent = nil

        if let pipeline {
            pipeline.shutdown()
        } else {
            recorder?.close()
        }
        pipeline = nil
        recorder = nil
        burst.reset()
        gapPolicy.reset()
        abandonEyeBreakRestIfNeeded()
        stopEyeBreakTimer()
        eyeBreakTimer.reset()
        lastValidFaceAt = nil
        publish()
    }

    /// One-click pause: camera off, no reminders, cadence suspended.
    func pause() {
        assert(Thread.isMainThread)
        guard isRunning, !isPaused else { return }
        settings.paused = true
        pauseInternal()
        settingsDidChange()
    }

    private func pauseInternal() {
        isPaused = true
        cancelTimers()
        stopCurrentBurst()
        scheduler.suspend(at: clock.monotonicNow)
        pipeline?.stopCamera()
        burst.reset()
        nudgePolicy.resetLowStreak()
        gapPolicy.reset()
        abandonEyeBreakRestIfNeeded()
        stopEyeBreakTimer()
        eyeBreakTimer.reset()
        lastValidFaceAt = nil
        setStatus("Paused — camera off, no reminders.")
        publish()
    }

    func resume() {
        assert(Thread.isMainThread)
        guard isRunning, isPaused else { return }
        settings.paused = false
        resumeInternal()
        settingsDidChange()
    }

    private func resumeInternal() {
        isPaused = false
        powerObserver.start()
        rateEstimator.reset()
        nudgePolicy.resetLowStreak()
        burst.reset()
        gapPolicy.reset()
        lastValidFaceAt = nil
        eyeBreakTimer.start(at: clock.monotonicNow)
        scheduleEyeBreakEvaluation()

        if cameraDenied {
            setStatus(settings.eyeBreaksEnabled
                ? "Camera unavailable — 20-20-20 breaks on."
                : "Camera access denied. Enable Blinko in System Settings › Privacy & Security › Camera.")
            publish()
            return
        }

        scheduler.start(at: clock.monotonicNow, immediateBurst: true)
        evaluateSchedule()
    }

    func retryCamera() {
        assert(Thread.isMainThread)
        guard isRunning, !isPaused else { return }

        cameraDenied = false
        gapPolicy.reset()
        lastValidFaceAt = nil
        scheduler.start(at: clock.monotonicNow, immediateBurst: true)
        requestCamera()
    }

    /// Menu/debug "Sample Now": starts a burst without waiting for the cadence.
    func sampleNow() {
        assert(Thread.isMainThread)
        guard isRunning, !isPaused, !cameraDenied else { return }
        guard !isSystemBlocked else { return }

        scheduler.forceBurst(at: clock.monotonicNow)
        evaluateSchedule(ignoringGate: true)
    }

    func setEyeBreaksEnabled(_ enabled: Bool) {
        assert(Thread.isMainThread)
        guard settings.eyeBreaksEnabled != enabled else { return }
        settings.eyeBreaksEnabled = enabled
        if !enabled { abandonEyeBreakRestIfNeeded() }
        eyeBreakTimer.setEnabled(enabled, at: clock.monotonicNow)
        if enabled {
            scheduleEyeBreakEvaluation()
        } else {
            stopEyeBreakTimer()
        }
        settingsDidChange()
        publish()
    }

    /// Updates the 20-20-20 cadence and re-arms from now.
    func setEyeBreakInterval(_ seconds: Double) {
        assert(Thread.isMainThread)
        let interval = min(3600, max(60, seconds))
        guard settings.eyeBreakIntervalSeconds != interval else { return }
        settings.eyeBreakIntervalSeconds = interval
        eyeBreakTimer.setInterval(interval, at: clock.monotonicNow)
        scheduleEyeBreakEvaluation()
        settingsDidChange()
        publish()
    }

    /// Updates how long the look-away card stays up.
    func setEyeBreakRestSeconds(_ seconds: Double) {
        assert(Thread.isMainThread)
        let rest = min(120, max(5, seconds))
        guard settings.eyeBreakRestSeconds != rest else { return }
        settings.eyeBreakRestSeconds = rest
        eyeBreakTimer.setRestSeconds(rest, at: clock.monotonicNow)
        // A shorter rest can move restEndsAt earlier; re-arm so the card is
        // hidden at the new deadline instead of the old one.
        scheduleEyeBreakEvaluation()
        settingsDidChange()
        publish()
    }

    /// Menu action: start a break now and reset the automatic cadence.
    func takeEyeBreakNow() {
        assert(Thread.isMainThread)
        guard isRunning, !isPaused else { return }
        if case .beginRest = eyeBreakTimer.beginNow(at: clock.monotonicNow) {
            deliverNudge(.eyeBreak)
        }
        scheduleEyeBreakEvaluation()
        publish()
    }

    func setSoundEnabled(_ enabled: Bool) {
        assert(Thread.isMainThread)
        guard settings.soundEnabled != enabled else { return }
        settings.soundEnabled = enabled
        settingsDidChange()
        publish()
    }

    func setQuietHoursEnabled(_ enabled: Bool) {
        assert(Thread.isMainThread)
        guard settings.quietHours.enabled != enabled else { return }
        settings.quietHours.enabled = enabled
        if enabled {
            enterQuietHours()
        } else {
            leaveQuietHours()
        }
        settingsDidChange()
        publish()
    }

    private func enterQuietHours() {
        // Do not fire immediately when quiet hours switch on, and stop the
        // camera right away rather than waiting for the next gate check.
        gapPolicy.start(at: clock.monotonicNow)
        if scheduler.isBursting {
            cancelTimers()
            stopCurrentBurst()
            scheduler.abortBurst(at: clock.monotonicNow)
            // Keep a slow retry alive so sampling resumes when the window
            // ends without requiring the menu toggle to be pressed again.
            scheduleNextEvaluation()
            setStatus("Camera off — quiet hours.")
        }
    }

    private func leaveQuietHours() {
        guard !isPaused, !cameraDenied, !isSystemBlocked else { return }
        scheduler.resume(at: clock.monotonicNow)
        scheduleNextEvaluation()
    }

    /// Changes the duty cycle while running. The active burst, if any, is
    /// shortened/extended according to the new duration and the cadence timer
    /// is re-armed immediately.
    func setDutyCycle(burstSeconds: Double, intervalSeconds: Double) {
        assert(Thread.isMainThread)

        let burstDuration = min(30, max(3, burstSeconds))
        let cadence = min(300, max(burstDuration, intervalSeconds))
        guard burstDuration != settings.burstSeconds || cadence != settings.intervalSeconds else {
            return
        }

        settings.burstSeconds = burstDuration
        settings.intervalSeconds = cadence

        let now = clock.monotonicNow
        scheduler.setBurstSeconds(burstDuration, at: now)
        scheduler.setInterval(cadence, at: now)
        if isRunning, !isPaused, !cameraDenied {
            scheduleNextEvaluation()
        }
        settingsDidChange()
        publish()
    }

    /// Updates the no-blink interval and re-arms the watchdog immediately.
    func setNoBlinkInterval(_ seconds: Double) {
        assert(Thread.isMainThread)
        guard seconds > 0, settings.noBlinkInterval != seconds else { return }
        settings.noBlinkInterval = seconds
        gapPolicy.setInterval(seconds, at: clock.monotonicNow)
        settingsDidChange()
        publish()
    }

    /// Updates the card's auto-dismiss duration. Zero means "until a blink".
    func setAutoDismissSeconds(_ seconds: Double) {
        assert(Thread.isMainThread)
        guard seconds >= 0, settings.autoDismissSeconds != seconds else { return }
        settings.autoDismissSeconds = seconds
        settingsDidChange()
        publish()
    }

    /// Remembers the login-item intent. `SMAppService` is the actual state.
    func setLaunchAtLogin(_ enabled: Bool) {
        assert(Thread.isMainThread)
        guard settings.launchAtLogin != enabled else { return }
        settings.launchAtLogin = enabled
        settingsDidChange()
        publish()
    }

    /// Applies a whole settings document from the Settings window or after a
    /// delete-all-data reset, reconfiguring the live monitor in one step.
    func apply(settings newSettings: Settings) {
        assert(Thread.isMainThread)
        let previous = settings
        settings = newSettings

        if newSettings.burstSeconds != previous.burstSeconds
            || newSettings.intervalSeconds != previous.intervalSeconds {
            let now = clock.monotonicNow
            scheduler.setBurstSeconds(newSettings.burstSeconds, at: now)
            scheduler.setInterval(newSettings.intervalSeconds, at: now)
        }
        if newSettings.noBlinkInterval != previous.noBlinkInterval {
            gapPolicy.setInterval(newSettings.noBlinkInterval, at: clock.monotonicNow)
        }

        if newSettings.paused != isPaused {
            if newSettings.paused {
                pauseInternal()
            } else {
                resumeInternal()
            }
        } else if !isPaused {
            if newSettings.quietHours.enabled != previous.quietHours.enabled {
                if newSettings.quietHours.enabled {
                    enterQuietHours()
                } else {
                    leaveQuietHours()
                }
            }

            if isRunning, !cameraDenied {
                scheduleNextEvaluation()
            }
        }

        if newSettings.eyeBreaksEnabled != previous.eyeBreaksEnabled {
            if !newSettings.eyeBreaksEnabled { abandonEyeBreakRestIfNeeded() }
            eyeBreakTimer.setEnabled(newSettings.eyeBreaksEnabled, at: clock.monotonicNow)
            if !newSettings.eyeBreaksEnabled {
                stopEyeBreakTimer()
            }
        }
        if newSettings.eyeBreakIntervalSeconds != previous.eyeBreakIntervalSeconds {
            eyeBreakTimer.setInterval(
                newSettings.eyeBreakIntervalSeconds,
                at: clock.monotonicNow
            )
        }
        if newSettings.eyeBreakRestSeconds != previous.eyeBreakRestSeconds {
            eyeBreakTimer.setRestSeconds(
                newSettings.eyeBreakRestSeconds,
                at: clock.monotonicNow
            )
        }
        scheduleEyeBreakEvaluation()

        settingsDidChange()
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

        let wasBursting = scheduler.isBursting
        // `shutdown()` closes the previous recorder before the new one starts.
        pipeline?.shutdown()
        pipeline = nil
        self.recorder = recorder

        if wasBursting {
            startCapture()
        }
    }

    // MARK: - Calibration

    /// Runs the guided ~5 s calibration: collects open-eye openness during a
    /// burst and seeds the detector with the median.
    func startCalibration() {
        assert(Thread.isMainThread)
        guard isRunning, !isPaused, !cameraDenied else {
            onCalibrationState?(.failed("Start Blinko and allow camera access before calibrating."))
            return
        }
        guard !isSystemBlocked else {
            onCalibrationState?(.failed("Calibration is unavailable while the screen is locked or the Mac is asleep."))
            return
        }

        calibrationTimer?.invalidate()
        calibrationTimer = nil
        calibrationCollector = CalibrationCollector()
        calibrationStartedAt = clock.monotonicNow
        onCalibrationState?(.collecting(progress: 0))

        if !scheduler.isBursting {
            sampleNow()
        }

        let timer = Timer(timeInterval: calibrationDuration, repeats: false) { [weak self] _ in
            self?.finishCalibration()
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        calibrationTimer = timer
    }

    func cancelCalibration() {
        assert(Thread.isMainThread)
        guard calibrationCollector != nil else { return }
        resetCalibrationState(notify: false)
        onCalibrationState?(.idle)
        setStatus("Calibration cancelled.")
        publish()
    }

    private func finishCalibration() {
        guard let collector = calibrationCollector else { return }
        calibrationTimer?.invalidate()
        calibrationTimer = nil
        calibrationCollector = nil
        calibrationStartedAt = nil

        let result = collector.finish()
        guard let baseline = result.baseline, baseline.isFinite,
              (0.01...1.0).contains(baseline) else {
            onCalibrationState?(.failed(
                "Not enough open-eye data. Face the camera in good light and try again."
            ))
            publish()
            return
        }

        pipeline?.detector.calibrate(with: collector.samples)
        settings.calibrationBaseline = baseline
        settings.calibrationDate = clock.now
        gapPolicy.start(at: clock.monotonicNow)
        settingsDidChange()
        onCalibrationState?(.completed(baseline: baseline))
        setStatus(String(format: "Calibrated — baseline %.3f.", baseline))
        publish()
    }

    private func abortCalibration(reason: String?) {
        guard calibrationCollector != nil else { return }
        resetCalibrationState(notify: false)
        if let reason {
            onCalibrationState?(.failed(reason))
        } else {
            onCalibrationState?(.idle)
        }
    }

    private func resetCalibrationState(notify: Bool) {
        calibrationTimer?.invalidate()
        calibrationTimer = nil
        calibrationCollector = nil
        calibrationStartedAt = nil
        if notify { onCalibrationState?(.idle) }
    }

    // MARK: - Camera

    private func requestCamera() {
        setStatus("Requesting camera access…")
        publish()
        CameraFrameSource.requestCameraAccess { [weak self] granted in
            guard let self, self.isRunning, !self.isPaused else { return }

            if granted {
                self.cameraDenied = false
                self.scheduler.start(at: self.clock.monotonicNow, immediateBurst: true)
                self.evaluateSchedule()
            } else {
                self.handleCameraUnavailable()
            }
        }
    }

    private func startCapture() {
        let pipeline: DetectionPipeline
        if let existing = self.pipeline {
            pipeline = existing
        } else {
            let created = DetectionPipeline(recorder: recorder)
            created.delegate = self
            if let baseline = settings.calibrationBaseline, baseline > 0 {
                created.detector.calibrate(with: [baseline])
            }
            self.pipeline = created
            pipeline = created
        }
        pipeline.startCamera()
    }

    private func handleCameraUnavailable(
        status message: String = "Camera access denied. Enable Blinko in System Settings › Privacy & Security › Camera.",
        discardCamera: Bool = false
    ) {
        cameraDenied = true
        cancelTimers()
        abortCalibration(reason: "Camera unavailable during calibration.")
        stopCurrentBurst()
        scheduler.stop()
        if discardCamera {
            // A missing/changed device needs a fresh configuration on retry.
            pipeline?.resetCamera()
        } else {
            pipeline?.stopCamera()
        }
        burst.reset()
        gapPolicy.reset()
        lastValidFaceAt = nil
        // Eye breaks are independent of the camera, so keep them armed.
        scheduleEyeBreakEvaluation()
        setStatus(message)
        publish()
    }

    // MARK: - Duty cycle

    private var isSystemBlocked: Bool {
        isAsleep || areScreensAsleep || isScreenLocked || !isSessionActive
    }

    private func evaluateSchedule(ignoringGate: Bool = false) {
        guard isRunning, !isPaused, !cameraDenied else { return }

        let now = clock.monotonicNow
        let conditions = currentConditions(now: now)
        let suppression = burstGate.suppression(for: conditions)
        let allowed = ignoringGate || suppression.isEmpty

        switch scheduler.action(at: now, allowed: allowed) {
        case .startBurst:
            startBurst(at: now)
        case .endBurst:
            endBurst(at: now)
        case .none:
            if !scheduler.isBursting, let reason = suppression.shortDescription {
                setStatus("Camera off — \(reason).")
            }
        }

        scheduleNextEvaluation()
        publishIfChanged()
    }

    private func startBurst(at now: TimeInterval) {
        activity.begin()
        burst.begin(at: now)
        gapPolicy.start(at: now)
        lastValidFaceAt = nil
        startCapture()
        startHeartbeat()
        setStatus("Sampling — camera on.")
        publish()
    }

    private func endBurst(at now: TimeInterval) {
        if calibrationCollector != nil {
            // A burst that ends before the 5 s window cannot produce a stable
            // baseline; ask for a retry instead of seeding from a partial run.
            abortCalibration(reason: "Calibration was cut short by the sampling window. Please try again.")
        }
        stopHeartbeat()
        pipeline?.stopCamera()
        // Deliver the final coalesced batch while the burst is still open.
        // Otherwise the 30 Hz hand-off lands after `isBursting` flips false and
        // `ingest` drops those samples and blinks.
        pipeline?.drainPendingDeliveries()
        finishBurst(at: now)
        gapPolicy.reset()
        lastValidFaceAt = nil
        activity.end()
        setStatus("Camera off — next sample in \(Int(settings.intervalSeconds.rounded())) s.")
        publish()
    }

    /// Abandons a burst in progress without producing a summary (pause, lock,
    /// sleep, quiet hours, camera loss).
    private func stopCurrentBurst() {
        guard scheduler.isBursting else { return }
        abortCalibration(reason: "Calibration interrupted.")
        stopHeartbeat()
        pipeline?.stopCamera()
        burst.reset()
        gapPolicy.reset()
        lastValidFaceAt = nil
        activity.end()
    }

    private func finishBurst(at now: TimeInterval) {
        guard let summary = burst.finish(at: now) else { return }
        rateEstimator.ingest(summary)
        onBurstCompleted?(summary)
    }

    private func scheduleNextEvaluation() {
        scheduleTimer?.invalidate()
        scheduleTimer = nil

        guard isRunning, !isPaused, !cameraDenied else { return }
        guard let deadline = scheduler.nextDeadline(after: clock.monotonicNow) else { return }

        let delay = max(0.05, deadline - clock.monotonicNow)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.evaluateSchedule()
        }
        // Spec §5: a timer with tolerance, so the scheduler is not pinned awake.
        timer.tolerance = min(5, max(0.1, delay * 0.1))
        RunLoop.main.add(timer, forMode: .common)
        scheduleTimer = timer
    }

    private func cancelTimers() {
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        stopHeartbeat()
    }

    // MARK: - Detection input

    private func ingest(sample: EyeSample, detector: DetectorSample) {
        guard isRunning, !isPaused, scheduler.isBursting else { return }

        onSample?(sample, detector)

        if sample.valid {
            lastValidFaceAt = sample.timestamp
        }
        burst.record(sample)

        if let collector = calibrationCollector, sample.valid, let openness = sample.openness {
            collector.add(openness: openness)
        }
    }

    private func ingest(blink: BlinkEvent) {
        guard isRunning, !isPaused, scheduler.isBursting else { return }
        burst.recordBlink()
        gapPolicy.recordBlink(at: blink.end)
        onBlink?(blink)
    }

    // MARK: - Heartbeat (only during a burst)

    private func startHeartbeat() {
        stopHeartbeat()
        // 2 Hz keeps the no-blink watchdog accurate while the camera is on.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.heartbeat()
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    private func heartbeat() {
        guard isRunning, !isPaused, scheduler.isBursting else { return }

        let now = clock.monotonicNow
        if let started = calibrationStartedAt {
            let progress = min(1, max(0, (now - started) / calibrationDuration))
            onCalibrationState?(.collecting(progress: progress))
            publishIfChanged()
            return
        }
        let facePresent = lastValidFaceAt.map { now - $0 <= 2 } ?? false
        let suppression = currentSuppression(now: now, includeCameraUnavailable: false)
        let decision = gapPolicy.evaluate(
            now: now,
            facePresent: facePresent,
            suppression: suppression
        )
        if case let .nudge(reason) = decision {
            deliverNudge(reason)
        }
        publishIfChanged()
    }

    // MARK: - 20-20-20 eye breaks

    /// Arms one tolerant one-shot timer at the next eye-break deadline. No
    /// per-second polling runs between breaks.
    private func scheduleEyeBreakEvaluation() {
        stopEyeBreakTimer()
        guard isRunning, !isPaused, !isSystemBlocked else { return }
        guard let deadline = eyeBreakTimer.nextDeadline() else { return }

        let delay = max(0.05, deadline - clock.monotonicNow)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.eyeBreakHeartbeat()
        }
        timer.tolerance = min(30, max(0.1, delay * 0.1))
        RunLoop.main.add(timer, forMode: .common)
        eyeBreakWakeTimer = timer
    }

    private func stopEyeBreakTimer() {
        eyeBreakWakeTimer?.invalidate()
        eyeBreakWakeTimer = nil
    }

    /// A rest can be abandoned without its deadline firing (pause, stop,
    /// system suspend or breaks disabled). Notify the UI so the card does not
    /// outlive the rest now that the presenter owns no timer for it.
    private func abandonEyeBreakRestIfNeeded() {
        guard eyeBreakTimer.isResting else { return }
        onEyeBreakCardEnded?()
    }

    private func eyeBreakHeartbeat() {
        guard isRunning, !isPaused else { return }

        let now = clock.monotonicNow
        let decision = eyeBreakTimer.evaluate(
            now: now,
            suppression: currentSuppression(now: now, includeCameraUnavailable: false)
        )
        switch decision {
        case .beginRest:
            deliverNudge(.eyeBreak)
        case .endRest:
            // The presenter does not run a second timer for eye breaks; the
            // monitor's rest deadline is the single source of truth.
            onEyeBreakCardEnded?()
        case .none, .suppressed:
            break
        }
        scheduleEyeBreakEvaluation()
        publishIfChanged()
    }

    // MARK: - Power events

    private func handle(powerEvent event: PowerEvent) {
        guard isRunning else { return }
        let now = clock.monotonicNow

        switch event {
        case .willSleep:
            isAsleep = true
            sleepStartedAt = now
            suspendForSystem(reason: "System asleep — camera off.")
        case .didWake:
            // Monotonic duration: a wall-clock change during sleep must not
            // affect whether stale rate/streak state is discarded.
            let asleepFor = sleepStartedAt.map { max(0, now - $0) } ?? 0
            sleepStartedAt = nil
            isAsleep = false
            resumeFromSystem(at: now, asleepFor: asleepFor)
        case .screensDidSleep:
            areScreensAsleep = true
            suspendForSystem(reason: "Screen asleep — camera off.")
        case .screensDidWake:
            areScreensAsleep = false
            resumeFromSystem(at: now, asleepFor: 0)
        case .screenLocked:
            isScreenLocked = true
            suspendForSystem(reason: "Screen locked — camera off.")
        case .screenUnlocked:
            isScreenLocked = false
            resumeFromSystem(at: now, asleepFor: 0)
        case .sessionResignedActive:
            isSessionActive = false
            suspendForSystem(reason: "Session inactive — camera off.")
        case .sessionBecameActive:
            isSessionActive = true
            resumeFromSystem(at: now, asleepFor: 0)
        }
    }

    private func suspendForSystem(reason: String) {
        cancelTimers()
        abandonEyeBreakRestIfNeeded()
        stopEyeBreakTimer()
        eyeBreakTimer.reset()
        stopCurrentBurst()
        scheduler.suspend(at: clock.monotonicNow)
        pipeline?.stopCamera()
        nudgePolicy.resetLowStreak()
        gapPolicy.reset()
        lastValidFaceAt = nil
        onSystemSuspend?()
        setStatus(reason)
        publish()
    }

    private func resumeFromSystem(at now: TimeInterval, asleepFor duration: TimeInterval) {
        guard isRunning, !isPaused, !isSystemBlocked else {
            publish()
            return
        }

        // Eye breaks work even when the camera is denied, so re-arm them before
        // the camera-specific resume path.
        eyeBreakTimer.start(at: now)
        scheduleEyeBreakEvaluation()

        guard !cameraDenied else {
            publish()
            return
        }

        let outcome = scheduler.handleWake(at: now, asleepFor: duration)
        if outcome == .restarted {
            rateEstimator.reset()
            nudgePolicy.resetLowStreak()
        }
        burst.reset()
        gapPolicy.reset()
        lastValidFaceAt = nil
        setStatus("Camera off — next sample in \(Int(settings.intervalSeconds.rounded())) s.")
        scheduleNextEvaluation()
        publish()
    }

    // MARK: - Conditions

    private func currentPresence(at now: TimeInterval) -> PresenceState {
        if now - presenceCheckedAt >= 1 {
            cachedPresence = presenceMonitor.current
            presenceCheckedAt = now
        }
        return cachedPresence
    }

    private func currentConditions(now: TimeInterval) -> BurstConditions {
        let presence = currentPresence(at: now)
        return BurstConditions(
            isPaused: isPaused,
            cameraDenied: cameraDenied,
            isAsleep: isAsleep || areScreensAsleep,
            isScreenLocked: isScreenLocked || !isSessionActive,
            isFullscreen: presence.isFullscreen,
            isDoNotDisturb: presence.isDoNotDisturb,
            isScreenSharing: presence.isScreenSharing,
            quietHoursActive: settings.quietHours.isActive(at: clock.now),
            secondsSinceInput: idleMonitor.secondsSinceLastInput,
            idleThreshold: settings.idleThresholdSeconds,
            batteryLevel: batteryMonitor.level,
            isPluggedIn: batteryMonitor.isPluggedIn,
            lowBatteryThreshold: settings.lowBatteryThreshold
        )
    }

    private func currentSuppression(
        now: TimeInterval,
        includeCameraUnavailable: Bool
    ) -> NudgeSuppression {
        var conditions = currentConditions(now: now)
        if !includeCameraUnavailable {
            conditions.cameraDenied = false
        }
        return burstGate.suppression(for: conditions)
    }

    // MARK: - Nudges

    private func deliverNudge(_ reason: NudgeReason) {
        deliveredNudgeCount += 1
        switch reason {
        case .noBlink:
            setStatus("Nudged: no blink for \(Int(settings.noBlinkInterval)) s.")
        case .lowRate:
            setStatus("Nudged: blink rate stayed low.")
        case .eyeBreak:
            setStatus("Nudged: 20-20-20 eye break.")
        }
        onNudge?(reason)
        publish()
    }

    // MARK: - Snapshot

    private func setStatus(_ text: String) {
        status = text
    }

    private func makeSnapshot() -> MonitorSnapshot {
        let now = clock.monotonicNow
        return MonitorSnapshot(
            isRunning: isRunning,
            isPaused: isPaused,
            cameraDenied: cameraDenied,
            quietHoursEnabled: settings.quietHours.enabled,
            quietHoursActive: settings.quietHours.isActive(at: clock.now),
            facePresent: lastValidFaceAt.map { now - $0 <= 2 } ?? false,
            secondsSinceBlink: gapPolicy.secondsSinceBlink(at: now),
            noBlinkInterval: settings.noBlinkInterval,
            autoDismissSeconds: settings.autoDismissSeconds,
            smoothedRate: rateEstimator.smoothedRate,
            lastBurstRate: rateEstimator.lastBurstRate,
            lowStreak: nudgePolicy.lowStreak,
            lowBurstsRequired: nudgePolicy.config.lowBurstsRequired,
            nudgeCount: deliveredNudgeCount,
            status: status,
            isBursting: scheduler.isBursting,
            nextBurstAt: scheduler.nextBurstAt,
            burstEndsAt: scheduler.burstEndsAt,
            burstSeconds: settings.burstSeconds,
            intervalSeconds: settings.intervalSeconds,
            suppression: currentSuppression(now: now, includeCameraUnavailable: false),
            eyeBreaksEnabled: settings.eyeBreaksEnabled,
            eyeBreakIntervalSeconds: settings.eyeBreakIntervalSeconds,
            eyeBreakRestSeconds: settings.eyeBreakRestSeconds,
            nextEyeBreakAt: eyeBreakTimer.nextBreakAt,
            isEyeBreaking: eyeBreakTimer.isResting
        )
    }

    /// Current state without publishing, for the Settings window.
    func snapshot() -> MonitorSnapshot {
        makeSnapshot()
    }

    private func settingsDidChange() {
        onSettingsChanged?(settings)
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
            handleCameraUnavailable(status: "No camera is available.", discardCamera: true)
        case .configurationFailed:
            handleCameraUnavailable(status: error.description, discardCamera: true)
        case .runtimeError:
            setStatus(error.description)
            publish()
        }
    }

    func detectionPipelineDidFinishReplay(_ pipeline: DetectionPipeline) {
        // The monitor never runs replay; AppDelegate owns that pipeline.
    }
}
