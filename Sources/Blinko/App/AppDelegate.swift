import AppKit
import UniformTypeIdentifiers
import BlinkoCore

struct LaunchOptions {
    var debugWindow = false
    var replayURL: URL?
    var recordURL: URL?
    /// Headless smoke-test aid: exit (with a summary) when a replay finishes.
    var exitAfterReplay = false

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        var index = 1

        while index < arguments.count {
            let argument = arguments[index]

            func nextValue() -> String? {
                index += 1
                guard index < arguments.count else { return nil }
                return arguments[index]
            }

            if argument == "--debug" {
                options.debugWindow = true
            } else if argument == "--exit-after-replay" {
                options.exitAfterReplay = true
            } else if argument == "--replay" {
                if let value = nextValue() {
                    options.replayURL = URL(fileURLWithPath: value)
                }
            } else if argument.hasPrefix("--replay=") {
                let path = String(argument.dropFirst("--replay=".count))
                if !path.isEmpty {
                    options.replayURL = URL(fileURLWithPath: path)
                }
            } else if argument == "--record" {
                if let value = nextValue() {
                    options.recordURL = URL(fileURLWithPath: value)
                }
            } else if argument.hasPrefix("--record=") {
                let path = String(argument.dropFirst("--record=".count))
                if !path.isEmpty {
                    options.recordURL = URL(fileURLWithPath: path)
                }
            }

            index += 1
        }

        return options
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private var monitor: BlinkMonitor?
    private var nudgePresenter: NudgePresenter?
    private var debugModel: DebugModel?
    private var debugWindow: DebugWindowController?
    private var options = LaunchOptions()
    private var replayURL: URL?
    private var recordURL: URL?
    private var replayPipeline: DetectionPipeline?
    private var resumeMonitoringAfterReplay = false

    private var isVerbose: Bool { options.exitAfterReplay || options.debugWindow }

    private func log(_ message: String) {
        guard isVerbose else { return }
        FileHandle.standardError.write(Data(("[blinko] \(message)\n").utf8))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        options = LaunchOptions.parse(CommandLine.arguments)
        replayURL = options.replayURL
        recordURL = options.recordURL
        log(
            "launch: debug=\(options.debugWindow) replay=\(options.replayURL?.path ?? "nil") "
            + "exitAfterReplay=\(options.exitAfterReplay)"
        )
        _ = NSApp.setActivationPolicy(.accessory)

        nudgePresenter = NudgePresenter()

        let menuBar = MenuBarController()
        menuBar.onShowDebug = { [weak self] in self?.showDebugWindow() }
        menuBar.onReplay = { [weak self] in self?.chooseReplayFile() }
        menuBar.onRecord = { [weak self] in self?.chooseRecordingFile() }
        menuBar.onTogglePause = { [weak self] in self?.togglePause() }
        menuBar.onToggleFallback = { [weak self] in self?.toggleFallback() }
        menuBar.onToggleQuietHours = { [weak self] in self?.toggleQuietHours() }
        menuBar.onSetBlinkInterval = { [weak self] seconds in self?.setBlinkInterval(seconds) }
        menuBar.onSetAutoDismiss = { [weak self] seconds in self?.setAutoDismiss(seconds) }
        menuBar.onSetDutyCycle = { [weak self] burst, interval in
            self?.monitor?.setDutyCycle(burstSeconds: burst, intervalSeconds: interval)
        }
        menuBar.onSampleNow = { [weak self] in self?.monitor?.sampleNow() }
        menuBar.onRetryCamera = { [weak self] in self?.monitor?.retryCamera() }
        menuBar.onQuit = { NSApp.terminate(nil) }
        self.menuBar = menuBar

        if options.replayURL != nil {
            menuBar.showReplayMode()
            showDebugWindow()
            startReplayIfNeeded()
        } else {
            startMonitoring()
            if options.debugWindow {
                showDebugWindow()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        monitor = nil
        replayPipeline?.shutdown()
        replayPipeline = nil
        debugModel?.stop()
        nudgePresenter?.dismiss()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Live monitoring

    private func startMonitoring() {
        guard monitor == nil else { return }

        let monitor = BlinkMonitor(clock: SystemClock(), settings: Settings())
        monitor.onSnapshot = { [weak self] snapshot in
            self?.menuBar?.update(snapshot: snapshot)
            self?.debugModel?.update(monitor: snapshot)
        }
        monitor.onSample = { [weak self] sample, detector in
            self?.debugModel?.ingest(sample: sample, detector: detector)
        }
        monitor.onBlink = { [weak self] blink in
            self?.debugModel?.record(blink: blink)
            // A blink means the reminder has done its job: hide it at once
            // instead of waiting for the auto-dismiss timer.
            self?.nudgePresenter?.dismiss()
        }
        monitor.onNudge = { [weak self] reason in
            self?.presentNudge(reason: reason)
        }
        monitor.onError = { [weak self] error in
            self?.debugModel?.setStatus(error.description)
            self?.log("camera error: \(error.description)")
        }
        monitor.onSystemSuspend = { [weak self] in
            self?.nudgePresenter?.dismiss()
        }
        self.monitor = monitor

        monitor.start(recorder: makeRecorderIfNeeded())
    }

    private func togglePause() {
        guard let monitor else { return }
        if monitor.isPaused {
            monitor.resume()
        } else {
            nudgePresenter?.dismiss()
            monitor.pause()
        }
    }

    private func toggleFallback() {
        guard let monitor else { return }
        monitor.setFallbackRemindersEnabled(!monitor.settings.fallbackRemindersEnabled)
    }

    private func toggleQuietHours() {
        guard let monitor else { return }
        monitor.setQuietHoursEnabled(!monitor.settings.quietHours.enabled)
    }

    private func setBlinkInterval(_ seconds: Double) {
        monitor?.setNoBlinkInterval(seconds)
    }

    private func setAutoDismiss(_ seconds: Double) {
        monitor?.setAutoDismissSeconds(seconds)
        // Restart a visible card's pending dismissal with the new duration.
        nudgePresenter?.setAutoDismissSeconds(seconds)
    }

    private func presentNudge(reason: NudgeReason) {
        nudgePresenter?.present(
            reason: reason,
            soundEnabled: monitor?.settings.soundEnabled ?? false,
            autoDismissSeconds: monitor?.settings.autoDismissSeconds ?? 2.5
        )
        menuBar?.pulse()

        switch reason {
        case .noBlink: log("nudge: no blink for \(Int(monitor?.settings.noBlinkInterval ?? 0)) s")
        case .lowRate: log("nudge: low blink rate")
        case .timedFallback: log("nudge: timed fallback")
        }
    }

    private func makeRecorderIfNeeded() -> LandmarkCSVRecorder? {
        guard let url = recordURL else { return nil }
        do {
            let recorder = try LandmarkCSVRecorder(url: url)
            debugModel?.setRecording(true)
            return recorder
        } catch {
            log("could not open \(url.lastPathComponent) for recording: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Debug window

    private func showDebugWindow() {
        let model: DebugModel
        if let existing = debugModel {
            model = existing
        } else {
            model = DebugModel()
            debugModel = model
        }

        if debugWindow == nil {
            let controller = DebugWindowController(
                model: model,
                onPreviewNudge: { [weak self] in self?.previewNudge() },
                onSampleNow: { [weak self] in self?.monitor?.sampleNow() }
            )
            controller.onClose = { [weak self] in
                guard let self else { return }
                self.debugModel?.stop()
                if self.replayPipeline != nil || self.resumeMonitoringAfterReplay {
                    self.stopReplayAndMaybeResumeMonitoring()
                }
            }
            debugWindow = controller
        }

        debugWindow?.show()
        model.start()
    }

    private func previewNudge() {
        nudgePresenter?.present(
            reason: .noBlink,
            soundEnabled: monitor?.settings.soundEnabled ?? false,
            autoDismissSeconds: monitor?.settings.autoDismissSeconds ?? 2.5
        )
        menuBar?.pulse()
    }

    // MARK: - Replay

    private func startReplayIfNeeded() {
        guard let url = replayURL else { return }

        let model = debugModel ?? DebugModel()
        if debugModel == nil {
            debugModel = model
        }

        stopReplayPipeline()
        model.clearMonitorState()

        let pipeline = DetectionPipeline(recorder: makeRecorderIfNeeded())
        pipeline.delegate = self
        replayPipeline = pipeline

        model.start()
        model.resetCounters()
        model.setStatus("Replaying \(url.lastPathComponent)…")
        pipeline.startReplay(url: url, pace: !options.exitAfterReplay)
    }

    private func stopReplayPipeline() {
        replayPipeline?.shutdown()
        replayPipeline = nil
        debugModel?.stop()
    }

    private func stopReplayAndMaybeResumeMonitoring() {
        stopReplayPipeline()
        guard resumeMonitoringAfterReplay else { return }
        resumeMonitoringAfterReplay = false
        startMonitoring()
    }

    // MARK: - File pickers (sandbox-safe access to recorded sessions)

    private func chooseReplayFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a landmark CSV recorded by Blinko."
        panel.prompt = "Replay"
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }

            self.replayURL = url
            self.recordURL = nil
            self.resumeMonitoringAfterReplay = self.monitor != nil
            self.nudgePresenter?.dismiss()
            self.monitor?.stop()
            self.monitor = nil
            self.menuBar?.showReplayMode()
            self.showDebugWindow()
            self.startReplayIfNeeded()
        }
    }

    private func chooseRecordingFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "blinko-session.csv"
        panel.message = "Landmark rows only — camera frames are never saved."
        panel.prompt = "Record"
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.recordURL = url

            if let monitor = self.monitor {
                do {
                    let recorder = try LandmarkCSVRecorder(url: url)
                    monitor.setRecorder(recorder)
                    self.debugModel?.setRecording(true)
                    self.debugModel?.setStatus("Recording landmarks to \(url.lastPathComponent)…")
                } catch {
                    self.recordURL = nil
                    self.showError("Could not open \(url.lastPathComponent) for recording.", error)
                }
            } else if self.replayPipeline != nil || self.replayURL != nil {
                self.startReplayIfNeeded()
            } else {
                self.startMonitoring()
            }
        }
    }

    private func showError(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

extension AppDelegate: DetectionPipelineDelegate {
    func detectionPipeline(
        _ pipeline: DetectionPipeline,
        didProduce sample: EyeSample,
        detector: DetectorSample
    ) {
        debugModel?.ingest(sample: sample, detector: detector)
    }

    func detectionPipeline(_ pipeline: DetectionPipeline, didDetect blink: BlinkEvent) {
        debugModel?.record(blink: blink)
    }

    func detectionPipeline(_ pipeline: DetectionPipeline, didFail error: FrameSourceError) {
        if options.exitAfterReplay {
            FileHandle.standardError.write(Data("[replay] error: \(error.description)\n".utf8))
            exit(1)
        }
        debugModel?.setStatus(error.description)
    }

    func detectionPipelineDidFinishReplay(_ pipeline: DetectionPipeline) {
        let model = debugModel
        let frames = model?.framesSeen ?? 0
        let blinks = model?.blinkCount ?? 0
        let baseline = pipeline.detector.baseline.map { String(format: "%.3f", $0) } ?? "n/a"
        log("replay finished: frames=\(frames) blinks=\(blinks) baseline=\(baseline)")

        // The replay source is done; close any recorder it was writing.
        pipeline.shutdown()
        replayPipeline = nil

        if options.exitAfterReplay {
            FileHandle.standardError.write(
                Data("[replay] frames=\(frames) blinks=\(blinks) baseline=\(baseline)\n".utf8)
            )
            NSApp.terminate(nil)
            return
        }

        debugModel?.setStatus("Replay finished.")
        if resumeMonitoringAfterReplay {
            resumeMonitoringAfterReplay = false
            startMonitoring()
        }
    }
}
