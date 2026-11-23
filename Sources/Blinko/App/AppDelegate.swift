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
    private var pipeline: DetectionPipeline?
    private var debugModel: DebugModel?
    private var debugWindow: DebugWindowController?
    private var options = LaunchOptions()
    private var pipelineRunning = false
    private var replayURL: URL?
    private var recordURL: URL?

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

        let menuBar = MenuBarController()
        menuBar.onShowDebug = { [weak self] in self?.showDebugWindow() }
        menuBar.onReplay = { [weak self] in self?.chooseReplayFile() }
        menuBar.onRecord = { [weak self] in self?.chooseRecordingFile() }
        menuBar.onQuit = { NSApp.terminate(nil) }
        self.menuBar = menuBar

        if options.debugWindow || options.replayURL != nil {
            showDebugWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopPipeline()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
            let controller = DebugWindowController(model: model)
            controller.onClose = { [weak self] in
                guard let self else { return }
                self.stopPipeline()
                self.debugModel?.setStatus("Stopped. Reopen from the menu bar to start again.")
            }
            debugWindow = controller
        }
        debugWindow?.show()

        if !pipelineRunning {
            startPipeline(model: model)
        }
    }

    private func startPipeline(model: DebugModel) {
        log("starting pipeline (replay=\(replayURL?.lastPathComponent ?? "none"))")
        var recorder: LandmarkCSVRecorder?
        if let url = recordURL {
            do {
                recorder = try LandmarkCSVRecorder(url: url)
                model.setStatus("Recording landmarks to \(url.lastPathComponent)…")
                model.setRecording(true)
            } catch {
                model.setStatus("Could not open \(url.lastPathComponent) for recording: \(error.localizedDescription)")
            }
        }

        let pipeline = DetectionPipeline(recorder: recorder)
        pipeline.delegate = self
        self.pipeline = pipeline
        pipelineRunning = true
        model.start()
        model.resetCounters()

        if let replayURL {
            model.setStatus("Replaying \(replayURL.lastPathComponent)…")
            pipeline.startReplay(url: replayURL, pace: !options.exitAfterReplay)
            return
        }

        model.setStatus("Requesting camera access…")
        CameraFrameSource.requestCameraAccess { [weak self] granted in
            guard let self, self.pipelineRunning else { return }
            if granted {
                model.setStatus("Camera running — blink deliberately to check detection.")
                self.pipeline?.startCamera()
            } else {
                model.setStatus(
                    "Camera access denied. Enable Blinko in System Settings › Privacy & Security › Camera, "
                    + "or launch with --replay <file.csv>."
                )
            }
        }
    }

    private func stopPipeline() {
        pipeline?.shutdown()
        pipeline = nil
        pipelineRunning = false
        debugModel?.stop()
        debugModel?.setRecording(false)
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
            self.restartPipeline()
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
            self.replayURL = nil
            self.restartPipeline()
        }
    }

    private func restartPipeline() {
        stopPipeline()
        showDebugWindow()
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

        if options.exitAfterReplay {
            FileHandle.standardError.write(
                Data("[replay] frames=\(frames) blinks=\(blinks) baseline=\(baseline)\n".utf8)
            )
            NSApp.terminate(nil)
            return
        }
        debugModel?.setStatus("Replay finished.")
    }
}
