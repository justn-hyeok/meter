import AppKit
import MeterCore
import SwiftUI

/// The settings window: what used to be reachable only from the CLI or a tile's
/// right-click menu, in one place.
struct SettingsView: View {
    @Bindable var store: UsageStore
    let alerts: AlertCenter
    let hotKeys: HotKeyController

    var body: some View {
        TabView {
            GeneralSettingsTab(store: store, alerts: alerts, hotKeys: hotKeys)
                .tabItem { Label("General", systemImage: "gearshape") }
            ProvidersSettingsTab(store: store, alerts: alerts)
                .tabItem { Label("Providers", systemImage: "square.grid.2x2") }
            WarningsSettingsTab(store: store, alerts: alerts)
                .tabItem { Label("Warnings", systemImage: "bell.badge") }
        }
        .frame(width: 520)
        .frame(minHeight: 420)
    }
}

/// The settings window, opened by hand rather than through SwiftUI's `Settings` scene.
///
/// A menu bar app has no app menu and is never active by itself, and `openSettings` from
/// inside a MenuBarExtra panel can open nothing or open behind the app in front. An
/// NSWindow this app owns opens in front every time.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(store: UsageStore, alerts: AlertCenter, hotKeys: HotKeyController) {
        if window == nil {
            let created = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(store: store, alerts: alerts, hotKeys: hotKeys)))
            created.title = "Meter Settings"
            // Resizable and tall by default: the Providers tab lists every provider.
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            created.setContentSize(NSSize(width: 520, height: 640))
            created.isReleasedWhenClosed = false
            created.identifier = NSUserInterfaceItemIdentifier("MeterSettings")
            created.center()
            window = created
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The footer's way into settings.
struct SettingsButton: View {
    let store: UsageStore
    let alerts: AlertCenter
    let hotKeys: HotKeyController

    var body: some View {
        Button {
            SettingsWindow.show(store: store, alerts: alerts, hotKeys: hotKeys)
        } label: {
            // A gear alone was easy to miss among the footer's controls.
            Label("Settings", systemImage: "gearshape")
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Meter's settings")
    }
}
