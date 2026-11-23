import AppKit
import BlinkoCore

/// Shows and auto-dismisses the nudge overlay. Re-presenting an already visible
/// nudge restarts the dismissal timer instead of stacking panels.
final class NudgePresenter {
    private var panel: NudgePanel?
    private var dismissWorkItem: DispatchWorkItem?

    func present(reason: NudgeReason, soundEnabled: Bool = false) {
        assert(Thread.isMainThread)

        let panel = panel ?? NudgePanel()
        self.panel = panel
        panel.update(reason: reason)
        panel.positionOnActiveScreen()
        panel.show()

        if soundEnabled, let sound = NSSound(named: "Pop") {
            sound.play()
        }

        dismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        dismissWorkItem = workItem
        // Spec §6: auto-dismiss in under 3 s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: workItem)
    }

    func dismiss() {
        assert(Thread.isMainThread)
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        panel?.hide()
    }
}
