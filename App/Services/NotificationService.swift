import Foundation
import UserNotifications
import HarborCore

/// Crash / port-conflict notifications. Fails soft: if the user denies
/// permission, calls simply do nothing.
enum NotificationService {
    private static var authorizationRequested = false

    static func requestAuthorizationIfNeeded() {
        authorizationRequested = true
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    static func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                center.add(request)
            default:
                break
            }
        }
    }
}
