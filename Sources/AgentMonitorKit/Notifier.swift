import Foundation
import UserNotifications

package enum NotificationActionIdentifier {
    package static let open = "open"
    package static let snooze = "snooze"
    package static let dismiss = "dismiss"
}

package enum NotificationCategoryIdentifier {
    package static let needsPermissionJump = "needs_permission_jump"
    package static let needsPermissionNoJump = "needs_permission_no_jump"
    package static let actionableJump = "actionable_jump"
    package static let actionableNoJump = "actionable_no_jump"
}

package enum NotificationActionResponse: Equatable, Sendable {
    case jump(agentId: String)
    case openPanel
    case snooze(agentId: String)
    case dismiss(agentId: String)
    case none
}

package enum Notifier {
    @MainActor package static var onAction: ((NotificationActionResponse) -> Void)?

    private static let delegate = Delegate()

    /// UNUserNotificationCenter traps when the binary runs outside an app bundle (e.g. `swift run`).
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    package static func categoryIdentifier(for item: MonitorModel.NotificationItem) -> String? {
        guard item.agentId != nil else { return nil }
        guard item.title != "Gemini CLI berhenti" else { return nil }
        guard let state = item.state else { return nil }

        switch state {
        case .needsPermission:
            return item.canJump
                ? NotificationCategoryIdentifier.needsPermissionJump
                : NotificationCategoryIdentifier.needsPermissionNoJump
        case .waiting, .failed, .finished:
            return item.canJump
                ? NotificationCategoryIdentifier.actionableJump
                : NotificationCategoryIdentifier.actionableNoJump
        default:
            return nil
        }
    }

    package static func resolveAction(
        actionIdentifier: String,
        agentId: String?,
        canJump: Bool
    ) -> NotificationActionResponse {
        switch actionIdentifier {
        case NotificationActionIdentifier.open, UNNotificationDefaultActionIdentifier:
            if let agentId, canJump {
                return .jump(agentId: agentId)
            } else {
                return .openPanel
            }
        case NotificationActionIdentifier.snooze:
            if let agentId {
                return .snooze(agentId: agentId)
            }
            return .none
        case NotificationActionIdentifier.dismiss:
            if let agentId {
                return .dismiss(agentId: agentId)
            }
            return .none
        default:
            return .none
        }
    }

    package static func resolveAction(
        actionIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> NotificationActionResponse {
        let agentId = userInfo["agentId"] as? String
        let canJump = userInfo["canJump"] as? Bool ?? false
        return resolveAction(actionIdentifier: actionIdentifier, agentId: agentId, canJump: canJump)
    }

    package static func makeCategories() -> Set<UNNotificationCategory> {
        let openAction = UNNotificationAction(
            identifier: NotificationActionIdentifier.open,
            title: "Buka",
            options: [.foreground]
        )
        let snoozeAction = UNNotificationAction(
            identifier: NotificationActionIdentifier.snooze,
            title: "Tunda 10 mnt",
            options: []
        )
        let dismissAction = UNNotificationAction(
            identifier: NotificationActionIdentifier.dismiss,
            title: "Tutup pantauan",
            options: []
        )

        let catNeedsPermJump = UNNotificationCategory(
            identifier: NotificationCategoryIdentifier.needsPermissionJump,
            actions: [openAction, snoozeAction],
            intentIdentifiers: [],
            options: []
        )
        let catNeedsPermNoJump = UNNotificationCategory(
            identifier: NotificationCategoryIdentifier.needsPermissionNoJump,
            actions: [snoozeAction],
            intentIdentifiers: [],
            options: []
        )
        let catActionableJump = UNNotificationCategory(
            identifier: NotificationCategoryIdentifier.actionableJump,
            actions: [openAction, snoozeAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )
        let catActionableNoJump = UNNotificationCategory(
            identifier: NotificationCategoryIdentifier.actionableNoJump,
            actions: [snoozeAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )

        return [catNeedsPermJump, catNeedsPermNoJump, catActionableJump, catActionableNoJump]
    }

    package static func requestPermission() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.setNotificationCategories(makeCategories())
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    package static func post(_ item: MonitorModel.NotificationItem) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = item.title
        content.body = item.message
        content.sound = .default
        content.threadIdentifier = item.threadIdentifier
        var userInfo: [AnyHashable: Any] = [:]
        if let agentId = item.agentId {
            userInfo["agentId"] = agentId
        }
        userInfo["canJump"] = item.canJump
        content.userInfo = userInfo
        if let categoryId = categoryIdentifier(for: item) {
            content.categoryIdentifier = categoryId
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    package static func post(_ title: String, _ body: String) {
        post(MonitorModel.NotificationItem(title: title, message: body))
    }

    /// Shows banners even while the menu bar panel is open, and routes actions to MonitorModel.
    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            completionHandler([.banner, .sound])
        }

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse,
            withCompletionHandler completionHandler: @escaping () -> Void
        ) {
            defer { completionHandler() }
            let action = Notifier.resolveAction(
                actionIdentifier: response.actionIdentifier,
                userInfo: response.notification.request.content.userInfo
            )
            if action != .none {
                Task { @MainActor in
                    Notifier.onAction?(action)
                }
            }
        }
    }
}
