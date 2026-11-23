import AppKit
import BlinkoCore

/// Subtle, non-activating reminder overlay (spec §6).
///
/// The panel never becomes key or main, ignores mouse events so clicks pass
/// through, and is dismissed automatically by `NudgePresenter`.
final class NudgePanel: NSPanel {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Blink")
    private let subtitleLabel = NSTextField(labelWithString: "Rest your eyes for a moment")
    private var showGeneration = 0

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 88),
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

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        contentView = background

        iconView.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)
        iconView.contentTintColor = .labelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .labelColor

        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(iconView)
        background.addSubview(textStack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            iconView.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 30),
            iconView.heightAnchor.constraint(equalToConstant: 30),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -16),
            textStack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(reason: NudgeReason) {
        switch reason {
        case .lowRate:
            titleLabel.stringValue = "Blink"
            subtitleLabel.stringValue = "You have blinked less than usual."
        case .timedFallback:
            titleLabel.stringValue = "Look away"
            subtitleLabel.stringValue = "20-20-20: rest your eyes for 20 seconds."
        }
    }

    /// Places the panel just below the menu bar on the screen under the pointer.
    func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let size = frame.size
        let origin = NSPoint(
            x: visible.maxX - size.width - 18,
            y: visible.maxY - size.height - 18
        )
        setFrameOrigin(origin)
    }

    func show() {
        showGeneration += 1
        orderFrontRegardless()
        animator().alphaValue = 1
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
}
