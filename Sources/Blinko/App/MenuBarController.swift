import AppKit

final class MenuBarController: NSObject {
    var onShowDebug: (() -> Void)?
    var onReplay: (() -> Void)?
    var onRecord: (() -> Void)?
    var onQuit: (() -> Void)?

    private let statusItem: NSStatusItem

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Blinko")
            button.image?.isTemplate = true
            button.toolTip = "Blinko"
        }

        let menu = NSMenu()

        let debugItem = NSMenuItem(
            title: "Show Detection Debug…",
            action: #selector(showDebug),
            keyEquivalent: "d"
        )
        debugItem.target = self
        menu.addItem(debugItem)

        let replayItem = NSMenuItem(
            title: "Replay Recorded Session…",
            action: #selector(replay),
            keyEquivalent: "r"
        )
        replayItem.target = self
        menu.addItem(replayItem)

        let recordItem = NSMenuItem(
            title: "Record Landmark Session…",
            action: #selector(record),
            keyEquivalent: ""
        )
        recordItem.target = self
        menu.addItem(recordItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Blinko",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func showDebug() {
        onShowDebug?()
    }

    @objc private func replay() {
        onReplay?()
    }

    @objc private func record() {
        onRecord?()
    }

    @objc private func quit() {
        onQuit?()
    }
}
