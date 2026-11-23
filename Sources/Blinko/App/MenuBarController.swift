import AppKit
import QuartzCore

final class MenuBarController: NSObject {
    var onShowDebug: (() -> Void)?
    var onReplay: (() -> Void)?
    var onRecord: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onToggleFallback: (() -> Void)?
    var onRetryCamera: (() -> Void)?
    var onQuit: (() -> Void)?

    private let statusItem: NSStatusItem
    private let statusLineItem: NSMenuItem
    private let pauseItem: NSMenuItem
    private let fallbackItem: NSMenuItem
    private let retryItem: NSMenuItem

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusLineItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        pauseItem = NSMenuItem(title: "Pause Blinko", action: nil, keyEquivalent: "p")
        fallbackItem = NSMenuItem(title: "Enable Timed Reminders", action: nil, keyEquivalent: "")
        retryItem = NSMenuItem(title: "Retry Camera", action: nil, keyEquivalent: "")

        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Blinko")
            button.image?.isTemplate = true
            button.toolTip = "Blinko"
        }

        statusLineItem.isEnabled = false

        pauseItem.target = self
        pauseItem.action = #selector(togglePause)

        fallbackItem.target = self
        fallbackItem.action = #selector(toggleFallback)
        fallbackItem.isHidden = true

        retryItem.target = self
        retryItem.action = #selector(retryCamera)
        retryItem.isHidden = true

        let debugItem = NSMenuItem(
            title: "Show Detection Debug…",
            action: #selector(showDebug),
            keyEquivalent: "d"
        )
        debugItem.target = self

        let replayItem = NSMenuItem(
            title: "Replay Recorded Session…",
            action: #selector(replay),
            keyEquivalent: "r"
        )
        replayItem.target = self

        let recordItem = NSMenuItem(
            title: "Record Landmark Session…",
            action: #selector(record),
            keyEquivalent: ""
        )
        recordItem.target = self

        let quitItem = NSMenuItem(
            title: "Quit Blinko",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self

        let menu = NSMenu()
        menu.addItem(statusLineItem)
        menu.addItem(.separator())
        menu.addItem(pauseItem)
        menu.addItem(fallbackItem)
        menu.addItem(retryItem)
        menu.addItem(.separator())
        menu.addItem(debugItem)
        menu.addItem(replayItem)
        menu.addItem(recordItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - State

    func update(snapshot: MonitorSnapshot) {
        let active = snapshot.isRunning && !snapshot.isPaused && !snapshot.cameraDenied
        setIcon(active ? "eye" : "eye.slash", toolTip: snapshot.status)

        pauseItem.title = snapshot.isPaused ? "Resume Blinko" : "Pause Blinko"
        pauseItem.isEnabled = snapshot.isRunning

        fallbackItem.isHidden = !snapshot.cameraDenied
        fallbackItem.title = snapshot.fallbackEnabled
            ? "Disable Timed Reminders"
            : "Enable Timed Reminders"

        retryItem.isHidden = !snapshot.cameraDenied

        statusLineItem.title = statusLine(for: snapshot)
    }

    /// Replay is a diagnostic mode: no camera, no reminders.
    func showReplayMode() {
        setIcon("eye.slash", toolTip: "Blinko — replay mode")
        statusLineItem.title = "Replay mode — reminders off"
        pauseItem.isEnabled = false
        fallbackItem.isHidden = true
        retryItem.isHidden = true
    }

    /// A short, unobtrusive attention pulse on the menu bar icon.
    func pulse() {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        guard let layer = button.layer else { return }

        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.25
        animation.duration = 0.22
        animation.autoreverses = true
        animation.repeatCount = 2
        layer.add(animation, forKey: "blinko.pulse")
    }

    private func setIcon(_ symbol: String, toolTip: String) {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Blinko")
        button.image?.isTemplate = true
        button.toolTip = toolTip
    }

    private func statusLine(for snapshot: MonitorSnapshot) -> String {
        if snapshot.isPaused { return "Paused — no reminders" }
        if !snapshot.isRunning { return "Stopped" }
        if snapshot.cameraDenied {
            return snapshot.fallbackEnabled
                ? "Camera unavailable — timed reminders on"
                : "Camera unavailable"
        }

        let rate = snapshot.smoothedRate.map { String(format: "%.1f blinks/min", $0) }
            ?? "Measuring…"

        if snapshot.quietHoursActive {
            return "\(rate) · quiet hours"
        }
        if snapshot.lowStreak > 0 {
            return "\(rate) · low \(snapshot.lowStreak)/\(snapshot.lowBurstsRequired)"
        }
        return rate
    }

    // MARK: - Actions

    @objc private func showDebug() {
        onShowDebug?()
    }

    @objc private func replay() {
        onReplay?()
    }

    @objc private func record() {
        onRecord?()
    }

    @objc private func togglePause() {
        onTogglePause?()
    }

    @objc private func toggleFallback() {
        onToggleFallback?()
    }

    @objc private func retryCamera() {
        onRetryCamera?()
    }

    @objc private func quit() {
        onQuit?()
    }
}
