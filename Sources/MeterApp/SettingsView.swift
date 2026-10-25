import AppKit
import MeterCore
import SwiftUI

/// The settings window: what used to be reachable only from the CLI or a tile's
/// right-click menu, in one place.
struct SettingsView: View {
    @Bindable var store: UsageStore
    let alerts: AlertCenter

    var body: some View {
        TabView {
            GeneralSettingsTab(store: store, alerts: alerts)
                .tabItem { Label("General", systemImage: "gearshape") }
            ProvidersSettingsTab(store: store)
                .tabItem { Label("Providers", systemImage: "square.grid.2x2") }
            WarningsSettingsTab(store: store)
                .tabItem { Label("Warnings", systemImage: "bell.badge") }
        }
        .frame(width: 520)
        .frame(minHeight: 420)
    }
}

/// The footer's way into settings. A menu bar app is never active on its own, so the
/// window would open behind whatever app is in front without the activation.
struct SettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            NSApp.activate()
            openSettings()
        } label: {
            Image(systemName: "gearshape")
        }
        .buttonStyle(.plain)
        .help("Settings")
        .accessibilityLabel("Settings")
    }
}
