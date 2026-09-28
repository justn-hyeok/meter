import Foundation
import MeterCore
import ServiceManagement
import UserNotifications

/// `SMAppService` and `UNUserNotificationCenter` both need a real app bundle; the second
/// traps outright without one. `swift run MeterApp` produces a bare executable, so both
/// features check this first and stay inert during development.
enum AppBundle {
    static var isBundled: Bool { Bundle.main.bundleIdentifier != nil }
}

@MainActor
enum LoginItem {
    static var isAvailable: Bool { AppBundle.isBundled }

    static var isEnabled: Bool {
        isAvailable && SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        guard isAvailable else { return }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

@MainActor
enum Notifier {
    static func requestAuthorization() {
        guard AppBundle.isBundled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    static func post(_ alerts: [UsageAlert]) {
        guard AppBundle.isBundled else { return }
        let center = UNUserNotificationCenter.current()
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            // One request per window and threshold, so a redelivery replaces rather than stacks.
            let identifier = "\(alert.provider.rawValue).\(alert.bucketID).\(alert.threshold)"
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }
}
