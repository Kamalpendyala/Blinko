import AppKit
import QuartzCore
import BlinkoCore

/// Prominent, non-activating reminder overlay.
///
/// The card is centered on the active screen, large enough to catch the eye
/// from any window, but it never becomes key or main and ignores mouse events
/// so clicks pass through. `NudgePresenter` dismisses it automatically.
final class NudgePanel: NSPanel {
    private let card = NSVisualEffectView()
    private let iconBackground = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Time to blink")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var showGeneration = 0

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 210),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        animationBehavior = .none

        card.material = .hudWindow
        card.blendingMode = .behindWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 26
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 2
        contentView = card

        iconBackground.wantsLayer = true
        iconBackground.layer?.cornerRadius = 46
        iconBackground.translatesAutoresizingMaskIntoConstraints = false

        iconView.image = NSImage(systemSymbolName: "eye.fill", accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 46, weight: .medium)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconBackground.addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 32, weight: .bold)
        titleLabel.textColor = .labelColor

        subtitleLabel.font = .systemFont(ofSize: 16, weight: .medium)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.preferredMaxLayoutWidth = 350

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 6
        textStack.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(iconBackground)
        card.addSubview(textStack)

        NSLayoutConstraint.activate([
            iconBackground.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 30),
            iconBackground.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            iconBackground.widthAnchor.constraint(equalToConstant: 92),
            iconBackground.heightAnchor.constraint(equalToConstant: 92),

            iconView.centerXAnchor.constraint(equalTo: iconBackground.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBackground.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 52),
            iconView.heightAnchor.constraint(equalToConstant: 52),

            textStack.leadingAnchor.constraint(equalTo: iconBackground.trailingAnchor, constant: 26),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -30),
            textStack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])

        apply(accent: .systemOrange)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(reason: NudgeReason) {
        switch reason {
        case .noBlink:
            titleLabel.stringValue = "Time to blink"
            subtitleLabel.stringValue = "No blink detected. Blink now and look away for a moment."
            apply(accent: .systemOrange)
        case .lowRate:
            titleLabel.stringValue = "Blink"
            subtitleLabel.stringValue = "You have blinked less than usual."
            apply(accent: .systemBlue)
        case .timedFallback:
            titleLabel.stringValue = "Look away"
            subtitleLabel.stringValue = "20-20-20: rest your eyes for 20 seconds."
            apply(accent: .systemTeal)
        }
    }

    /// Centers the card on the screen under the pointer.
    func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let size = frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        setFrameOrigin(origin)
    }

    func show() {
        showGeneration += 1
        if !isVisible {
            alphaValue = 0
        }
        orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }

        pulseIcon()
    }

    func hide() {
        guard isVisible else { return }

        let generation = showGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.showGeneration == generation else { return }
            self.orderOut(nil)
        }
    }

    private func apply(accent: NSColor) {
        card.layer?.borderColor = accent.withAlphaComponent(0.85).cgColor
        iconBackground.layer?.backgroundColor = accent.withAlphaComponent(0.18).cgColor
        iconView.contentTintColor = accent
    }

    private func pulseIcon() {
        iconView.wantsLayer = true
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 1.0
        pulse.toValue = 1.16
        pulse.duration = 0.32
        pulse.autoreverses = true
        pulse.repeatCount = 2
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        iconView.layer?.add(pulse, forKey: "blinko.icon.pulse")
    }
}
