import Foundation
import BlinkoCore

/// Everything the menu bar and debug window need to display, published at a
/// human pace rather than once per camera frame.
struct MonitorSnapshot: Equatable {
    var isRunning: Bool
    var isPaused: Bool
    var cameraDenied: Bool
    var fallbackEnabled: Bool
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
    private var scheduler: SamplingScheduler

    private var pipeline: DetectionPipeline?
    private var recorder: LandmarkCSVRecorder?
    private var scheduleTimer: Timer?
    private var heartbeatTimer: Timer?
    private var fallbackTimer: Timer?

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
        isPaused = false
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
        nudgePolicy.stopFallback()
        gapPolicy.reset()
        lastValidFaceAt = nil
        publish()
    }

    /// One-click pause: camera off, no reminders, cadence suspended.
    func pause() {
        assert(Thread.isMainThread)
        guard isRunning, !isPaused else { return }

        isPaused = true
        cancelTimers()
        stopCurrentBurst()
        scheduler.suspend(at: clock.monotonicNow)
        pipeline?.stopCamera()
        burst.reset()
        nudgePolicy.resetLowStreak()
        nudgePolicy.stopFallback()
        gapPolicy.reset()
        lastValidFaceAt = nil
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
        gapPolicy.reset()
        lastValidFaceAt = nil

        if cameraDenied {
            if settings.fallbackRemindersEnabled {
                nudgePolicy.beginFallback(at: clock.monotonicNow)
                setStatus("Camera unavailable — timed reminders on.")
                startFallbackTimerIfNeeded()
            } else {
                setStatus("Camera access denied. Enable timed reminders from the menu.")
            }
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
        nudgePolicy.stopFallback()
        stopFallbackTimer()
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

    func setFallbackRemindersEnabled(_ enabled: Bool) {
        assert(Thread.isMainThread)
        settings.fallbackRemindersEnabled = enabled

        if enabled, cameraDenied, !isPaused {
            nudgePolicy.beginFallback(at: clock.monotonicNow)
            startFallbackTimerIfNeeded()
        } else if !enabled {
            nudgePolicy.stopFallback()
            stopFallbackTimer()
        }
        publish()
    }

    func setSoundEnabled(_ enabled: Bool) {
        assert(Thread.isMainThread)
        settings.soundEnabled = enabled
        publish()
    }

    func setQuietHoursEnabled(_ enabled: Bool) {
        assert(Thread.isMainThread)
        settings.quietHours.enabled = enabled
        if enabled {
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
        } else if !isPaused, !cameraDenied, !isSystemBlocked {
            scheduler.resume(at: clock.monotonicNow)
            scheduleNextEvaluation()
        }
        publish()
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
        publish()
    }

    /// Updates the no-blink interval and re-arms the watchdog immediately.
    func setNoBlinkInterval(_ seconds: Double) {
        assert(Thread.isMainThread)
        guard seconds > 0 else { return }
        settings.noBlinkInterval = seconds
        gapPolicy.setInterval(seconds, at: clock.monotonicNow)
        publish()
    }

    /// Updates the card's auto-dismiss duration. Zero means "until a blink".
    func setAutoDismissSeconds(_ seconds: Double) {
        assert(Thread.isMainThread)
        guard seconds >= 0 else { return }
        settings.autoDismissSeconds = seconds
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
        stopCurrentBurst()
        scheduler.stop()
        if discardCamera {
            // A missing/changed device needs a fresh configuration on retry.
            pipeline?.resetCamera()
        } else {
            pipeline?.stopCamera()
        }
        burst.reset()
        nudgePolicy.stopFallback()
        gapPolicy.reset()
        lastValidFaceAt = nil
        if settings.fallbackRemindersEnabled {
            nudgePolicy.beginFallback(at: clock.monotonicNow)
            startFallbackTimerIfNeeded()
        }
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
        stopHeartbeat()
        pipeline?.stopCamera()
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
        stopFallbackTimer()
    }

    // MARK: - Detection input

    private func ingest(sample: EyeSample, detector: DetectorSample) {
        guard isRunning, !isPaused, scheduler.isBursting else { return }

        onSample?(sample, detector)

        if sample.valid {
            lastValidFaceAt = sample.timestamp
        }
        burst.record(sample)
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

    // MARK: - Camera-denied fallback

    private func startFallbackTimerIfNeeded() {
        guard isRunning, !isPaused, cameraDenied, settings.fallbackRemindersEnabled else {
            stopFallbackTimer()
            return
        }
        guard fallbackTimer == nil else { return }

        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.heartbeatFallback()
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    private func stopFallbackTimer() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    private func heartbeatFallback() {
        guard isRunning, !isPaused, cameraDenied, settings.fallbackRemindersEnabled else {
            stopFallbackTimer()
            return
        }

        let now = clock.monotonicNow
        let decision = nudgePolicy.evaluateFallback(
            now: now,
            enabled: true,
            cameraUnavailable: true,
            suppression: currentSuppression(now: now, includeCameraUnavailable: false)
        )
        if case let .nudge(reason) = decision {
            deliverNudge(reason)
        }
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
        guard isRunning, !isPaused, !cameraDenied, !isSystemBlocked else {
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
        case .timedFallback:
            setStatus("Nudged: timed reminder.")
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
            fallbackEnabled: settings.fallbackRemindersEnabled,
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
            suppression: currentSuppression(now: now, includeCameraUnavailable: false)
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
