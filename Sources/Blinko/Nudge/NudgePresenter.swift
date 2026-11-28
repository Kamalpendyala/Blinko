import AppKit
import BlinkoCore

/// Shows and auto-dismisses the nudge overlay. Re-presenting an already visible
/// nudge restarts the dismissal timer instead of stacking panels.
final class NudgePresenter {
    private var panel: NudgePanel?
    private var dismissWorkItem: DispatchWorkItem?
    private var autoDismissSeconds: Double = 2.5
    private(set) var isVisible = false
    private(set) var currentReason: NudgeReason?

    func present(
        reason: NudgeReason,
        soundEnabled: Bool = false,
        autoDismissSeconds: Double = 2.5
    ) {
        assert(Thread.isMainThread)

        // A new card supersedes any auto-dismiss still pending for the previous
        // one. Without this, a blink card's timer could hide a break card that
        // replaced it mid-countdown.
        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        let panel = panel ?? NudgePanel()
        self.panel = panel
        self.autoDismissSeconds = autoDismissSeconds
        self.currentReason = reason
        panel.update(reason: reason, restSeconds: autoDismissSeconds)
        panel.positionOnActiveScreen()
        panel.show()
        isVisible = true

        if soundEnabled, let sound = NSSound(named: "Pop") {
            sound.play()
        }

        // Eye breaks are ended by the monitor's rest deadline (which reports
        // through BlinkMonitor.onEyeBreakCardEnded). Adding a second timer here
        // would duplicate the countdown and could diverge if the rest duration
        // changes mid-break.
        guard reason != .eyeBreak else { return }
        scheduleAutoDismiss()
    }

    /// Applies a new duration. If a card is visible, its pending dismissal is
    /// restarted with the new value; zero means "wait for a blink". An eye-break
    /// card keeps its own rest duration and is never shortened by this.
    func setAutoDismissSeconds(_ seconds: Double) {
        assert(Thread.isMainThread)
        autoDismissSeconds = seconds
        guard isVisible, currentReason != .eyeBreak else { return }
        scheduleAutoDismiss()
    }

    /// A blink dismisses a blink reminder but not a 20-20-20 break: only the
    /// rest timer (or the user) ends a break.
    func dismissOnBlink() {
        assert(Thread.isMainThread)
        guard currentReason != .eyeBreak else { return }
        dismiss()
    }

    func dismiss() {
        assert(Thread.isMainThread)
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        isVisible = false
        currentReason = nil
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
