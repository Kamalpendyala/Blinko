import AppKit
import QuartzCore

final class MenuBarController: NSObject {
    var onShowDebug: (() -> Void)?
    var onReplay: (() -> Void)?
    var onRecord: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onToggleFallback: (() -> Void)?
    var onToggleQuietHours: (() -> Void)?
    var onSetBlinkInterval: ((Double) -> Void)?
    var onSetAutoDismiss: ((Double) -> Void)?
    var onSetDutyCycle: ((Double, Double) -> Void)?
    var onSampleNow: (() -> Void)?
    var onRetryCamera: (() -> Void)?
    var onQuit: (() -> Void)?

    private let statusItem: NSStatusItem
    private let statusLineItem: NSMenuItem
    private let pauseItem: NSMenuItem
    private let fallbackItem: NSMenuItem
    private let quietHoursItem: NSMenuItem
    private let blinkIntervalItem = NSMenuItem(title: "Blink Interval", action: nil, keyEquivalent: "")
    private let autoDismissItem = NSMenuItem(title: "Dismiss After", action: nil, keyEquivalent: "")
    private let samplingItem = NSMenuItem(title: "Sampling", action: nil, keyEquivalent: "")
    private let sampleNowItem = NSMenuItem(title: "Sample Now", action: nil, keyEquivalent: "s")
    private let retryItem: NSMenuItem
    private var blinkPresetItems: [(seconds: Double, item: NSMenuItem)] = []
    private var autoDismissPresetItems: [(seconds: Double, item: NSMenuItem)] = []
    private var dutyPresetItems: [(burst: Double, interval: Double, item: NSMenuItem)] = []
    private let blinkCustomItem = NSMenuItem(title: "Custom…", action: nil, keyEquivalent: "")
    private let autoDismissCustomItem = NSMenuItem(title: "Custom…", action: nil, keyEquivalent: "")
    private let autoDismissNeverItem = NSMenuItem(title: "Never", action: nil, keyEquivalent: "")
    private var currentNoBlinkInterval: Double = 5
    private var currentAutoDismissSeconds: Double = 2.5
    private var currentBurstSeconds: Double = 12
    private var currentIntervalSeconds: Double = 60
    private var lastSnapshot: MonitorSnapshot?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusLineItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        pauseItem = NSMenuItem(title: "Pause Blinko", action: nil, keyEquivalent: "p")
        fallbackItem = NSMenuItem(title: "Enable Timed Reminders", action: nil, keyEquivalent: "")
        quietHoursItem = NSMenuItem(title: "Quiet Hours (22:00–08:00)", action: nil, keyEquivalent: "")
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

        quietHoursItem.target = self
        quietHoursItem.action = #selector(toggleQuietHours)

        sampleNowItem.target = self
        sampleNowItem.action = #selector(sampleNow)
        sampleNowItem.isHidden = true

        retryItem.target = self
        retryItem.action = #selector(retryCamera)
        retryItem.isHidden = true

        configureIntervalMenus()
        configureDutyMenu()

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
        menu.addItem(quietHoursItem)
        menu.addItem(sampleNowItem)
        menu.addItem(retryItem)
        menu.addItem(.separator())
        menu.addItem(blinkIntervalItem)
        menu.addItem(autoDismissItem)
        menu.addItem(samplingItem)
        menu.addItem(.separator())
        menu.addItem(debugItem)
        menu.addItem(replayItem)
        menu.addItem(recordItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        statusItem.menu = menu
        menu.delegate = self
    }

    // MARK: - Interval menus

    private func configureIntervalMenus() {
        let blinkMenu = NSMenu()
        for seconds in [3.0, 5.0, 10.0, 15.0, 20.0, 30.0] {
            let item = NSMenuItem(
                title: "\(Self.secondsText(seconds)) s",
                action: #selector(selectBlinkPreset(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NSNumber(value: seconds)
            blinkMenu.addItem(item)
            blinkPresetItems.append((seconds, item))
        }
        blinkMenu.addItem(.separator())
        blinkCustomItem.target = self
        blinkCustomItem.action = #selector(customBlinkInterval)
        blinkMenu.addItem(blinkCustomItem)
        blinkIntervalItem.submenu = blinkMenu

        let dismissMenu = NSMenu()
        for seconds in [1.0, 2.5, 5.0, 10.0] {
            let item = NSMenuItem(
                title: "\(Self.secondsText(seconds)) s",
                action: #selector(selectAutoDismissPreset(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NSNumber(value: seconds)
            dismissMenu.addItem(item)
            autoDismissPresetItems.append((seconds, item))
        }
        dismissMenu.addItem(.separator())
        autoDismissNeverItem.target = self
        autoDismissNeverItem.action = #selector(selectAutoDismissPreset(_:))
        autoDismissNeverItem.representedObject = NSNumber(value: 0)
        dismissMenu.addItem(autoDismissNeverItem)
        autoDismissCustomItem.target = self
        autoDismissCustomItem.action = #selector(customAutoDismiss)
        dismissMenu.addItem(autoDismissCustomItem)
        autoDismissItem.submenu = dismissMenu
    }

    private static let dutyPresets: [(burst: Double, interval: Double)] = [
        (8, 40),
        (12, 60),
        (20, 120),
        (30, 300),
    ]

    private func configureDutyMenu() {
        let dutyMenu = NSMenu()
        for (index, preset) in Self.dutyPresets.enumerated() {
            let item = NSMenuItem(
                title: "\(Self.secondsText(preset.burst)) s every \(Self.secondsText(preset.interval)) s",
                action: #selector(selectDutyPreset(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = index
            dutyMenu.addItem(item)
            dutyPresetItems.append((preset.burst, preset.interval, item))
        }
        samplingItem.submenu = dutyMenu
    }

    private func updateIntervalMenus() {
        blinkIntervalItem.title = "Blink Interval: \(Self.secondsText(currentNoBlinkInterval)) s"
        let dismissText = currentAutoDismissSeconds <= 0
            ? "Never"
            : "\(Self.secondsText(currentAutoDismissSeconds)) s"
        autoDismissItem.title = "Dismiss After: \(dismissText)"
        samplingItem.title = "Sampling: \(Self.secondsText(currentBurstSeconds)) s / \(Self.secondsText(currentIntervalSeconds)) s"
        for preset in dutyPresetItems {
            let on = abs(preset.burst - currentBurstSeconds) < 0.0001
                && abs(preset.interval - currentIntervalSeconds) < 0.0001
            preset.item.state = on ? .on : .off
        }

        updatePresetChecks(
            blinkPresetItems,
            current: currentNoBlinkInterval,
            customItem: blinkCustomItem,
            includeNever: false
        )
        updatePresetChecks(
            autoDismissPresetItems,
            current: currentAutoDismissSeconds,
            customItem: autoDismissCustomItem,
            includeNever: true
        )
    }

    private func updatePresetChecks(
        _ presets: [(seconds: Double, item: NSMenuItem)],
        current: Double,
        customItem: NSMenuItem,
        includeNever: Bool
    ) {
        var matched = false
        for preset in presets {
            let on = abs(preset.seconds - current) < 0.0001
            preset.item.state = on ? .on : .off
            if on { matched = true }
        }

        if includeNever {
            let on = current <= 0
            autoDismissNeverItem.state = on ? .on : .off
            if on { matched = true }
        }

        customItem.state = matched ? .off : .on
        customItem.title = matched
            ? "Custom…"
            : "Custom… (\(Self.secondsText(current)) s)"
    }

    private func promptForSeconds(
        title: String,
        message: String,
        current: Double,
        range: ClosedRange<Double>
    ) -> Double? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(string: Self.secondsText(current))
        field.alignment = .right
        field.frame = NSRect(x: 0, y: 0, width: 160, height: 24)

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = NSNumber(value: range.lowerBound)
        formatter.maximum = NSNumber(value: range.upperBound)
        formatter.maximumFractionDigits = 1
        field.formatter = formatter

        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let value = field.doubleValue
        guard range.contains(value) else {
            NSSound.beep()
            return nil
        }
        return value
    }

    private static func secondsText(_ seconds: Double) -> String {
        if seconds == seconds.rounded() {
            return String(Int(seconds))
        }
        return String(format: "%.1f", seconds)
    }

    // MARK: - State

    func update(snapshot: MonitorSnapshot) {
        lastSnapshot = snapshot
        let active = snapshot.isRunning && !snapshot.isPaused && !snapshot.cameraDenied
        setIcon(active ? "eye" : "eye.slash", toolTip: snapshot.status)

        pauseItem.title = snapshot.isPaused ? "Resume Blinko" : "Pause Blinko"
        pauseItem.isEnabled = snapshot.isRunning

        fallbackItem.isHidden = !snapshot.cameraDenied
        fallbackItem.title = snapshot.fallbackEnabled
            ? "Disable Timed Reminders"
            : "Enable Timed Reminders"

        retryItem.isHidden = !snapshot.cameraDenied

        quietHoursItem.state = snapshot.quietHoursEnabled ? .on : .off
        quietHoursItem.isEnabled = snapshot.isRunning
        quietHoursItem.isHidden = false

        sampleNowItem.isHidden = !snapshot.isRunning
        sampleNowItem.isEnabled = active && !snapshot.isBursting

        currentNoBlinkInterval = snapshot.noBlinkInterval
        currentAutoDismissSeconds = snapshot.autoDismissSeconds
        currentBurstSeconds = snapshot.burstSeconds
        currentIntervalSeconds = snapshot.intervalSeconds
        blinkIntervalItem.isHidden = false
        autoDismissItem.isHidden = false
        samplingItem.isHidden = false
        blinkIntervalItem.isEnabled = snapshot.isRunning
        autoDismissItem.isEnabled = snapshot.isRunning
        updateIntervalMenus()

        statusLineItem.title = statusLine(for: snapshot)
    }

    /// Replay is a diagnostic mode: no camera, no reminders.
    func showReplayMode() {
        setIcon("eye.slash", toolTip: "Blinko — replay mode")
        statusLineItem.title = "Replay mode — reminders off"
        pauseItem.isEnabled = false
        fallbackItem.isHidden = true
        quietHoursItem.isHidden = true
        sampleNowItem.isHidden = true
        blinkIntervalItem.isHidden = true
        autoDismissItem.isHidden = true
        samplingItem.isHidden = true
        retryItem.isHidden = true
    }

    /// A single, short attention dip on the menu bar icon.
    func pulse() {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        guard let layer = button.layer else { return }

        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.45
        animation.duration = 0.18
        animation.autoreverses = true
        animation.repeatCount = 1
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

        if let reason = snapshot.suppression.shortDescription, !snapshot.isBursting {
            return "Camera off — \(reason)"
        }
        if snapshot.isBursting {
            return "\(rate) · sampling now"
        }
        if let next = snapshot.nextBurstAt {
            let remaining = max(0, next - ProcessInfo.processInfo.systemUptime)
            return "\(rate) · camera off, next in \(Int(remaining.rounded(.up)))s"
        }
        if snapshot.facePresent, let gap = snapshot.secondsSinceBlink {
            return String(
                format: "%@ · %.1fs / %@s no blink",
                rate,
                gap,
                Self.secondsText(snapshot.noBlinkInterval)
            )
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

    @objc private func toggleQuietHours() {
        onToggleQuietHours?()
    }

    @objc private func selectBlinkPreset(_ sender: NSMenuItem) {
        guard let seconds = (sender.representedObject as? NSNumber)?.doubleValue else { return }
        onSetBlinkInterval?(seconds)
    }

    @objc private func customBlinkInterval() {
        guard let value = promptForSeconds(
            title: "Blink Interval",
            message: "Show a reminder after this many seconds without a blink. Enter 1–300 seconds.",
            current: currentNoBlinkInterval,
            range: 1...300
        ) else { return }
        onSetBlinkInterval?(value)
    }

    @objc private func selectAutoDismissPreset(_ sender: NSMenuItem) {
        guard let seconds = (sender.representedObject as? NSNumber)?.doubleValue else { return }
        onSetAutoDismiss?(seconds)
    }

    @objc private func customAutoDismiss() {
        guard let value = promptForSeconds(
            title: "Dismiss After",
            message: "Hide the reminder card after this many seconds. Enter 0.5–60, or choose Never.",
            current: max(currentAutoDismissSeconds, 0.5),
            range: 0.5...60
        ) else { return }
        onSetAutoDismiss?(value)
    }

    @objc private func selectDutyPreset(_ sender: NSMenuItem) {
        let presets = Self.dutyPresets
        guard presets.indices.contains(sender.tag) else { return }
        let preset = presets[sender.tag]
        onSetDutyCycle?(preset.burst, preset.interval)
    }

    @objc private func retryCamera() {
        onRetryCamera?()
    }

    @objc private func sampleNow() {
        onSampleNow?()
    }

    @objc private func quit() {
        onQuit?()
    }
}

extension MenuBarController: NSMenuDelegate {
    /// Recomputes the countdown when the user opens the menu; no timer runs
    /// between bursts just to keep the menu title fresh.
    func menuWillOpen(_ menu: NSMenu) {
        guard let lastSnapshot else { return }
        statusLineItem.title = statusLine(for: lastSnapshot)
    }
}
