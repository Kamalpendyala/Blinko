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

    private var pending: [PlotSample] = []
    private var nextID = 0
    private var validCount = 0
    private var totalCount = 0
    private var flushTimer: Timer?

    // MARK: - Lifecycle

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
}
