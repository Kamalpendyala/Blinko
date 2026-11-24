import AppKit
import BlinkoCore

/// Shows and auto-dismisses the nudge overlay. Re-presenting an already visible
/// nudge restarts the dismissal timer instead of stacking panels.
final class NudgePresenter {
    private var panel: NudgePanel?
    private var dismissWorkItem: DispatchWorkItem?
    private var autoDismissSeconds: Double = 2.5
    private(set) var isVisible = false

    func present(
        reason: NudgeReason,
        soundEnabled: Bool = false,
        autoDismissSeconds: Double = 2.5
    ) {
        assert(Thread.isMainThread)

        let panel = panel ?? NudgePanel()
        self.panel = panel
        self.autoDismissSeconds = autoDismissSeconds
        panel.update(reason: reason)
        panel.positionOnActiveScreen()
        panel.show()
        isVisible = true

        if soundEnabled, let sound = NSSound(named: "Pop") {
            sound.play()
        }

        scheduleAutoDismiss()
    }

    /// Applies a new duration. If a card is visible, its pending dismissal is
    /// restarted with the new value; zero means "wait for a blink".
    func setAutoDismissSeconds(_ seconds: Double) {
        assert(Thread.isMainThread)
        autoDismissSeconds = seconds
        guard isVisible else { return }
        scheduleAutoDismiss()
    }

    func dismiss() {
        assert(Thread.isMainThread)
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        isVisible = false
        panel?.hide()
    }

    private func scheduleAutoDismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        // Zero (the "Never" menu option) leaves the card up until a blink.
        guard autoDismissSeconds > 0 else { return }

        let workItem = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + autoDismissSeconds, execute: workItem)
    }
}
