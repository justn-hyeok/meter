import AppKit
import Carbon.HIToolbox
import MeterCore
import SwiftUI

/// Refresh interval, launch at login, alerts and the global shortcut.
struct GeneralSettingsTab: View {
    @Bindable var store: UsageStore
    @Bindable var alerts: AlertCenter
    let hotKeys: HotKeyController

    @State private var loginItemFailure: String?
    @State private var monitor: Any?
    @State private var isRecording = false
    @State private var hint: String?

    var body: some View {
        Form {
            Section {
                Picker("Refresh every", selection: $store.refreshInterval) {
                    ForEach(MeterSettings.refreshIntervals, id: \.self) { interval in
                        Text(intervalText(interval)).tag(interval)
                    }
                }
            }

            Section {
                if LoginItem.isAvailable {
                    Toggle("Launch at login", isOn: loginItemBinding)
                }
                if AppBundle.isBundled {
                    Toggle("Alerts", isOn: $alerts.isEnabled)
                        .help("Notify when a limit passes 80% and 95%, or a sign-in stops working")
                }
                if let loginItemFailure {
                    Text(loginItemFailure).foregroundStyle(.red)
                }
                if alerts.isEnabled, alerts.isDenied {
                    Button("Notifications are off for Meter in System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                    .buttonStyle(.link)
                }
            }

            Section("Shortcut") {
                LabeledContent("Opens the menu") {
                    HStack(spacing: 8) {
                        Text(hotKeys.current.display)
                            .monospaced()
                            .foregroundStyle(hotKeys.current.isEnabled ? .primary : .tertiary)
                        Toggle("Shortcut", isOn: shortcutEnabled)
                            .labelsHidden()
                        Button(isRecording ? "Press a shortcut…" : "Record…") { startRecording() }
                            .disabled(!hotKeys.current.isEnabled)
                        Button("Reset to ⌃⌥M") {
                            stopRecording()
                            if !hotKeys.apply(.standard) { hint = Self.taken }
                        }
                        .disabled(hotKeys.current == .standard)
                    }
                }
                if let hint {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        // A monitor outlives the row it was started from: leaving the tab while recording
        // would otherwise keep swallowing every key press.
        .onDisappear { stopRecording() }
    }

    /// "1 minute", "2 minutes": the bare second counts the settings store holds say nothing
    /// about how long the wait feels.
    private func intervalText(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: { LoginItem.isEnabled },
            set: { newValue in
                do {
                    try LoginItem.setEnabled(newValue)
                    loginItemFailure = nil
                } catch {
                    loginItemFailure = error.localizedDescription
                }
            }
        )
    }

    private var shortcutEnabled: Binding<Bool> {
        Binding(
            get: { hotKeys.current.isEnabled },
            set: { isEnabled in
                stopRecording()
                var setting = hotKeys.current
                setting.isEnabled = isEnabled
                if !hotKeys.apply(setting) { hint = Self.taken }
            }
        )
    }

    private func startRecording() {
        guard monitor == nil else { return }
        isRecording = true
        hint = nil
        hotKeys.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Local monitors run on the main thread; the state they change lives there too.
            MainActor.assumeIsolated { record(event) }
            // Swallowed either way: a recorded shortcut must not also land in the field.
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isRecording { hotKeys.resume() }
        isRecording = false
        hint = nil
    }

    private func record(_ event: NSEvent) {
        guard isRecording, !event.isARepeat else { return }
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return
        }
        let modifiers = Self.carbonModifiers(event.modifierFlags)
        guard HotKeyDisplay.hasMenuModifier(modifiers) else {
            hint = "Add ⌘, ⌃ or ⌥ to make it a shortcut."
            return
        }
        let keyCode = Int(event.keyCode)
        stopRecording()
        let applied = hotKeys.apply(HotKeySetting(
            keyCode: keyCode,
            modifiers: modifiers,
            display: HotKeyDisplay.string(keyCode: keyCode, modifiers: modifiers)
        ))
        if !applied { hint = Self.taken }
    }

    private static let taken = "That shortcut is taken by another app or by macOS. Try another."

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var modifiers = 0
        if flags.contains(.command) { modifiers |= cmdKey }
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        return modifiers
    }
}
