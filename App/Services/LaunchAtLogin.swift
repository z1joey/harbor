import Foundation
import ServiceManagement
import HarborCore

/// Launch-at-login via SMAppService (macOS 13+). Dev builds that aren't in
/// /Applications may fail to register — the error is surfaced, not fatal.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registration succeeded but the user still has to approve the login
    /// item in System Settings — `isEnabled` stays false until then.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) -> Result<Void, HarborError> {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return .success(())
        } catch {
            return .failure(HarborError("Launch at login could not be \(enabled ? "enabled" : "disabled"): \(error.localizedDescription)"))
        }
    }
}
