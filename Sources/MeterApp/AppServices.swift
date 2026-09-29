import AppKit
import Foundation
import MeterCore
import ServiceManagement

/// `SMAppService` needs a real app bundle. `swift run MeterApp` produces a bare executable,
/// so launch at login checks this first and stays inert during development.
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
