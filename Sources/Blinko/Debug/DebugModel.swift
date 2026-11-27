import Foundation
import Combine
import BlinkoCore

/// Main-thread view model for the Phase A detection debug window.
///
/// Samples are buffered and flushed at 15 Hz so SwiftUI redraws stay cheap.
final class DebugModel: ObservableObject {
    struct PlotSample: Identifiable, Equatable {
        let id: Int
        let timestamp: TimeInterval
        let openness: Double?
        let valid: Bool
    }

    let windowSeconds: TimeInterval = 15

    @Published private(set) var samples: [PlotSample] = []
    @Published private(set) var blinkCount = 0
    @Published private(set) var baseline: Double?
    @Published private(set) var closedThreshold: Double?
    @Published private(set) var openThreshold: Double?
    @Published private(set) var latestOpenness: Double?
    @Published private(set) var validFraction: Double = 0
    @Published private(set) var status: String = "Idle."
    @Published private(set) var blinkTimestamps: [TimeInterval] = []
    @Published private(set) var phase: DetectorPhase = .calibrating
    @Published private(set) var framesSeen = 0
    @Published private(set) var isRecording = false

    @Published private(set) var smoothedRate: Double?
    @Published private(set) var lastBurstRate: Double?
    @Published private(set) var lowStreak = 0
    @Published private(set) var lowBurstsRequired = 3
    @Published private(set) var nudgeCount = 0
    @Published private(set) var isPaused = false
    @Published private(set) var monitorStatus = ""
    @Published private(set) var secondsSinceBlink: Double?
    @Published private(set) var noBlinkInterval: Double = 5
    @Published private(set) var autoDismissSeconds: Double = 2.5
    @Published private(set) var facePresent = false
    @Published private(set) var quietHoursActive = false

    // Phase C: duty-cycle readouts.
    @Published private(set) var isBursting = false
    @Published private(set) var burstSeconds: Double = 12
    @Published private(set) var intervalSeconds: Double = 60
    @Published private(set) var secondsUntilNextBurst: Double?
    @Published private(set) var burstElapsed: Double?
    @Published private(set) var suppression: NudgeSuppression = []

    // Phase E: 20-20-20 break readouts.
    @Published private(set) var eyeBreaksEnabled = true
    @Published private(set) var eyeBreakIntervalSeconds: Double = 20 * 60
    @Published private(set) var eyeBreakRestSeconds: Double = 20
    @Published private(set) var isEyeBreaking = false
    @Published private(set) var secondsUntilEyeBreak: Double?

    private let clock: Clock
    private var nextBurstAt: TimeInterval?
    private var burstEndsAt: TimeInterval?
    private var nextEyeBreakAt: TimeInterval?
    private var pending: [PlotSample] = []
    private var nextID = 0
    private var validCount = 0
    private var totalCount = 0
    private var flushTimer: Timer?

    // MARK: - Lifecycle

    init(clock: Clock = SystemClock()) {
        self.clock = clock
    }

    func start() {
        assert(Thread.isMainThread)
        guard flushTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            self?.flush()
        }
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
    }

    func stop() {
        assert(Thread.isMainThread)
        flushTimer?.invalidate()
        flushTimer = nil
    }

    func setStatus(_ text: String) {
        assert(Thread.isMainThread)
        status = text
    }

    func setRecording(_ recording: Bool) {
        assert(Thread.isMainThread)
        isRecording = recording
    }

    // MARK: - Ingest

    func ingest(sample: EyeSample, detector: DetectorSample) {
        assert(Thread.isMainThread)
        // No debug window: do not do per-frame UI work while monitoring.
        guard flushTimer != nil else { return }

        pending.append(
            PlotSample(
                id: nextID,
                timestamp: sample.timestamp,
                openness: sample.openness,
                valid: sample.valid
            )
        )
        nextID += 1
        framesSeen += 1
        totalCount += 1
        if sample.valid { validCount += 1 }

        latestOpenness = sample.openness
        baseline = detector.baseline
        closedThreshold = detector.closedThreshold
        openThreshold = detector.openThreshold
        phase = detector.phase

        if pending.count > 2_400 {
            flush()
        }
    }

    func record(blink: BlinkEvent) {
        assert(Thread.isMainThread)
        guard flushTimer != nil else { return }
        blinkCount += 1
        blinkTimestamps.append(blink.end)
    }

    func update(monitor: MonitorSnapshot) {
        assert(Thread.isMainThread)
        smoothedRate = monitor.smoothedRate
        lastBurstRate = monitor.lastBurstRate
        lowStreak = monitor.lowStreak
        lowBurstsRequired = monitor.lowBurstsRequired
        nudgeCount = monitor.nudgeCount
        isPaused = monitor.isPaused
        monitorStatus = monitor.status
        secondsSinceBlink = monitor.secondsSinceBlink
        noBlinkInterval = monitor.noBlinkInterval
        autoDismissSeconds = monitor.autoDismissSeconds
        facePresent = monitor.facePresent
        quietHoursActive = monitor.quietHoursActive
        isBursting = monitor.isBursting
        burstSeconds = monitor.burstSeconds
        intervalSeconds = monitor.intervalSeconds
        nextBurstAt = monitor.nextBurstAt
        burstEndsAt = monitor.burstEndsAt
        suppression = monitor.suppression
        eyeBreaksEnabled = monitor.eyeBreaksEnabled
        eyeBreakIntervalSeconds = monitor.eyeBreakIntervalSeconds
        eyeBreakRestSeconds = monitor.eyeBreakRestSeconds
        nextEyeBreakAt = monitor.nextEyeBreakAt
        isEyeBreaking = monitor.isEyeBreaking
        refreshCountdown()
    }

    /// Drops live-monitor fields when switching to replay/diagnostic mode.
    func clearMonitorState() {
        assert(Thread.isMainThread)
        smoothedRate = nil
        lastBurstRate = nil
        lowStreak = 0
        nudgeCount = 0
        isPaused = false
        monitorStatus = ""
        secondsSinceBlink = nil
        facePresent = false
        quietHoursActive = false
        autoDismissSeconds = 2.5
        isBursting = false
        secondsUntilNextBurst = nil
        burstElapsed = nil
        suppression = []
        nextBurstAt = nil
        burstEndsAt = nil
        eyeBreaksEnabled = true
        isEyeBreaking = false
        secondsUntilEyeBreak = nil
        nextEyeBreakAt = nil
    }

    func resetCounters() {
        assert(Thread.isMainThread)
        samples.removeAll()
        pending.removeAll()
        blinkTimestamps.removeAll()
        blinkCount = 0
        validCount = 0
        totalCount = 0
        framesSeen = 0
    }

    // MARK: - Flush

    private func flush() {
        assert(Thread.isMainThread)
        // The debug window's 15 Hz flush also drives the between-burst
        // countdown; no samples arrive while the camera is off.
        refreshCountdown()
        guard !pending.isEmpty else { return }

        samples.append(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)

        let cutoff = (samples.last?.timestamp ?? 0) - windowSeconds
        if let firstFresh = samples.firstIndex(where: { $0.timestamp >= cutoff }), firstFresh > 0 {
            samples.removeFirst(firstFresh)
        }
        blinkTimestamps.removeAll { $0 < cutoff }

        let valid = samples.lazy.filter(\.valid).count
        validFraction = samples.isEmpty ? 0 : Double(valid) / Double(samples.count)
    }

    /// Converts the monitor's monotonic deadlines into display values. Only
    /// runs while the debug window is open; the menu bar app itself has no
    /// per-second timer between bursts.
    private func refreshCountdown() {
        let now = clock.monotonicNow
        if let nextBurstAt {
            secondsUntilNextBurst = max(0, nextBurstAt - now)
        } else {
            secondsUntilNextBurst = nil
        }
        if let burstEndsAt {
            burstElapsed = max(0, burstSeconds - max(0, burstEndsAt - now))
        } else {
            burstElapsed = nil
        }
        if let nextEyeBreakAt {
            secondsUntilEyeBreak = max(0, nextEyeBreakAt - now)
        } else {
            secondsUntilEyeBreak = nil
        }
    }
}
