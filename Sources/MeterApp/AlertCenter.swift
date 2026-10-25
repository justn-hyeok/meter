import AppKit
import MeterCore
@preconcurrency import UserNotifications

/// Posts the alerts `UsageAlerts` decides on as macOS notifications.
///
/// Permission is asked for the first time an alert is due, not at launch: a Meter with
/// nothing near a limit has no reason to ask yet.
@MainActor
@Observable
final class AlertCenter: NSObject {
    private(set) var isDenied = false
    private let settings = MeterSettings()

    var isEnabled: Bool {
        didSet { settings.alertsEnabled = isEnabled }
    }

    override init() {
        isEnabled = settings.alertsEnabled
        super.init()
        // Notifications need a real bundle; `swift run MeterApp` has none and would crash.
        guard AppBundle.isBundled else { return }
        UNUserNotificationCenter.current().delegate = self
        Task { await refreshAuthorization() }
    }

    /// Called after every refresh. With alerts off, what is due is still recorded as sent,
    /// so switching them back on does not deliver a backlog at once.
    func check(_ snapshots: [UsageSnapshot]) {
        let result = UsageAlerts.evaluate(snapshots, sent: settings.alertsSent)
        settings.alertsSent = result.sent
        guard isEnabled, AppBundle.isBundled, !result.alerts.isEmpty else { return }
        Task { await post(result.alerts) }
    }

    func refreshAuthorization() async {
        guard AppBundle.isBundled else { return }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        isDenied = status == .denied
    }

    private func post(_ alerts: [UsageAlert]) async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        await refreshAuthorization()
        guard !isDenied else { return }
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: nil))
        }
    }
}

extension AlertCenter: UNUserNotificationCenterDelegate {
    /// A menu bar app counts as frontmost, and without this its own banners are dropped.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Clicking an alert opens the menu, where the figures and the fix are.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run { MenuBarToggle.toggle() }
    }
}
