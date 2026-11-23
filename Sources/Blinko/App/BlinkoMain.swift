import AppKit

@main
enum BlinkoMain {
    // NSApplication holds its delegate weakly, so keep a strong reference here.
    private static let appDelegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = appDelegate
        _ = app.setActivationPolicy(.accessory)
        app.run()
    }
}
