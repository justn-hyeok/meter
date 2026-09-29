import AppKit
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

/// What macOS will actually do with a notification Meter posts.
enum NotificationPermission: Equatable {
    case allowed
    /// Turned off in System Settings, so posting is silently discarded.
    case denied
    /// Not asked yet, or asked and dismissed.
    case notAsked
    /// No app bundle, so notifications are not available at all.
    case unavailable

    var blocksDelivery: Bool { self == .denied || self == .notAsked }
}

@MainActor
@Observable
final class Notifier {
    static let shared = Notifier()

    /// Read from macOS rather than assumed. The menu's own toggle said notifications were on
    /// while System Settings was discarding every one of them, which is the kind of thing
    /// this app is supposed to stop doing.
    private(set) var permission: NotificationPermission = AppBundle.isBundled ? .notAsked : .unavailable

    func requestAuthorization() {
        guard AppBundle.isBundled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshPermission() }
        }
    }

    func refreshPermission() {
        guard AppBundle.isBundled else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                self?.permission = switch status {
                case .authorized, .provisional, .ephemeral: .allowed
                case .denied: .denied
                default: .notAsked
                }
            }
        }
    }

    func openSystemSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }

    static func requestAuthorization() {
        shared.requestAuthorization()
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
