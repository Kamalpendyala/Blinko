import AppKit
import BlinkoCore

/// NSWorkspace-backed power observer (spec §5).
///
/// Sleep/wake and display sleep come from `NSWorkspace`; screen lock/unlock is
/// posted on the distributed notification center. Everything is delivered on
/// the main queue so `BlinkMonitor` can mutate its state without locking.
final class SystemPowerObserver: PowerObserver {
    var onEvent: ((PowerEvent) -> Void)?

    private let workspaceCenter = NSWorkspace.shared.notificationCenter
    private let distributedCenter = DistributedNotificationCenter.default()
    private var workspaceTokens: [NSObjectProtocol] = []
    private var distributedTokens: [NSObjectProtocol] = []

    func start() {
        guard workspaceTokens.isEmpty, distributedTokens.isEmpty else { return }

        observe(NSWorkspace.willSleepNotification, .willSleep)
        observe(NSWorkspace.didWakeNotification, .didWake)
        observe(NSWorkspace.screensDidSleepNotification, .screensDidSleep)
        observe(NSWorkspace.screensDidWakeNotification, .screensDidWake)
        observe(NSWorkspace.sessionDidResignActiveNotification, .sessionResignedActive)
        observe(NSWorkspace.sessionDidBecomeActiveNotification, .sessionBecameActive)

        distributedTokens.append(
            distributedCenter.addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.onEvent?(.screenLocked)
            }
        )
        distributedTokens.append(
            distributedCenter.addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.onEvent?(.screenUnlocked)
            }
        )
    }

    func stop() {
        workspaceTokens.forEach(workspaceCenter.removeObserver)
        workspaceTokens.removeAll()
        distributedTokens.forEach(distributedCenter.removeObserver)
        distributedTokens.removeAll()
    }

    private func observe(_ name: NSNotification.Name, _ event: PowerEvent) {
        workspaceTokens.append(
            workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.onEvent?(event)
            }
        )
    }
}
