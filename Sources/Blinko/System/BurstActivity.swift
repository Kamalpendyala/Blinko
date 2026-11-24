import Foundation

/// Holds a `ProcessInfo` activity assertion for the duration of one sampling
/// burst (spec §5): App Nap cannot starve the capture while it runs, and the
/// assertion is released between bursts so the Mac is never pinned awake.
final class BurstActivity {
    private var token: NSObjectProtocol?

    func begin() {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Blinko sampling burst"
        )
    }

    func end() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }
}
