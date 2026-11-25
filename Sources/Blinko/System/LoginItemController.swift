import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp`.
///
/// The service stores the registration itself, so moving the app does not
/// break the login item (AP-02); no executable path is ever persisted.
final class LoginItemController {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "Enabled — Blinko starts when you log in."
        case .notRegistered:
            return "Not registered as a login item."
        case .requiresApproval:
            return "Waiting for approval in System Settings › General › Login Items."
        case .notFound:
            return "Login item not found. Move Blinko to Applications and try again."
        @unknown default:
            return "Unknown login-item status."
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled {
                try service.register()
            }
        } else if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        }
    }
}
