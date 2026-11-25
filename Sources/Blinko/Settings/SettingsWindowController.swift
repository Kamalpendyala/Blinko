import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init(model: SettingsModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Blinko Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 580, height: 640)
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
