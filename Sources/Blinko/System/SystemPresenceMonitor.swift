import AppKit
import CoreGraphics
import BlinkoCore

/// Presentation-state suppression (spec §6).
///
/// Fullscreen and screen sharing are best-effort: fullscreen is a frontmost
/// window that exactly covers a display, and screen sharing is a known
/// screen-sharing app in the running list. Focus/Do Not Disturb has no public
/// API for a sandboxed ad-hoc app, so that flag stays false and quiet hours is
/// the reliable way to silence reminders (documented in the README).
final class SystemPresenceMonitor: PresenceMonitor {
    private static let screenSharingBundleIDs: Set<String> = [
        "com.apple.ScreenSharing",
        "com.apple.ScreenSharingViewer",
        "com.apple.screensharing.agent",
        "com.apple.screensharing.Menubar",
        "com.teamviewer.TeamViewer",
        "com.teamviewer.TeamViewerHost",
        "com.anydesk.AnyDesk",
        "com.microsoft.rdc.macos",
    ]

    var current: PresenceState {
        PresenceState(
            isFullscreen: isFrontmostAppFullscreen(),
            isDoNotDisturb: false,
            isScreenSharing: isScreenSharing()
        )
    }

    private func isFrontmostAppFullscreen() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return false }

        let pid = app.processIdentifier
        let screenSizes = NSScreen.screens.map(\.frame.size)
        guard !screenSizes.isEmpty,
              let windows = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID
              ) as? [[String: Any]]
        else { return false }

        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else { continue }

            // CGWindow bounds are in global screen coordinates; only the size
            // matters for a fullscreen window.
            if screenSizes.contains(where: {
                abs($0.width - bounds.width) <= 2 && abs($0.height - bounds.height) <= 2
            }) {
                return true
            }
        }
        return false
    }

    private func isScreenSharing() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            guard let bundleID = app.bundleIdentifier else { return false }
            return Self.screenSharingBundleIDs.contains(bundleID)
        }
    }
}
