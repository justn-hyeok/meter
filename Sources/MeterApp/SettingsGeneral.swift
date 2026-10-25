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
    @State private var percentsDraft = ""

    var body: some View {
        Form {
            Section {
                Picker("Refresh every", selection: $store.refreshInterval) {
                    ForEach(MeterSettings.refreshIntervals, id: \.self) { interval in
                        Text(intervalText(interval)).tag(interval)
                    }
                }
            }

            Section("Menu") {
                Picker("Width", selection: $store.menuWidth) {
                    ForEach(MenuWidth.allCases, id: \.self) { width in
                        Text(width.title)
                            .tag(width)
                            // A width the screen cannot hold would hang the menu off its edge.
                            // It stays listed, so it is clear the menu can be made wider on a
                            // larger screen.
                            .disabled(!MenuGeometry.fits(width, screenWidth: screenWidth))
                    }
                }
                if let tooWideNote {
                    Text(tooWideNote).font(.caption).foregroundStyle(.secondary)
                }
                Picker("Height", selection: $store.menuHeight) {
                    ForEach(MenuHeight.allCases, id: \.self) { height in
                        Text(height.title).tag(height)
                    }
                }
                Toggle("Fill gaps between tiles", isOn: $store.fillGaps)
                Text("A later tile moves up into a hole a bigger one left. Off keeps your order exactly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if LoginItem.isAvailable {
                    Toggle("Launch at login", isOn: loginItemBinding)
                }
                if AppBundle.isBundled {
                    Toggle("Alerts", isOn: $alerts.isEnabled)
                        .help("Notify at the percents below, once each, or when a sign-in stops working")
                    if alerts.isEnabled {
                        LabeledContent("Percents") {
                            // The title of a field in a form is drawn as its label, which here repeated the
                            // values beside them; the default is the placeholder, not a second label.
                            TextField("Percents", text: $percentsDraft, prompt: Text(AlertPercents.defaultText))
                                .labelsHidden()
                                .onSubmit { commitPercents() }
                        }
                        Text("Default for every window. A provider or a window can override this. Comma-separated.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
        .onAppear { percentsDraft = alerts.percentsText }
        // A monitor outlives the row it was started from: leaving the tab while recording
        // would otherwise keep swallowing every key press.
        .onDisappear {
            commitPercents()
            stopRecording()
        }
    }

    private func commitPercents() {
        alerts.percentsText = percentsDraft
        percentsDraft = alerts.percentsText
    }

    /// "1 minute", "2 minutes": the bare second counts the settings store holds say nothing
    /// about how long the wait feels.
    private func intervalText(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    /// The screen the menu opens on. Without one, nothing is ruled out: the menu's own clamp
    /// still keeps it on screen.
    private var screenWidth: CGFloat { NSScreen.main?.visibleFrame.width ?? .infinity }

    /// Shown only when a width really is out of reach, so the tab says nothing about screens
    /// that hold every choice.
    private var tooWideNote: String? {
        let unreachable = MenuWidth.allCases.contains { !MenuGeometry.fits($0, screenWidth: screenWidth) }
        return unreachable ? "Wider menus are off because they would not fit on this screen." : nil
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

/// One comma-separated percents field. Empty means inherit; junk is not saved.
struct AlertPercentsField: View {
    let placeholder: String
    let current: String
    let onCommit: (String) -> Void
    @State private var draft = ""

    var body: some View {
        TextField("Percents", text: $draft, prompt: Text(placeholder))
            .labelsHidden()
            .onAppear { draft = current }
            .onChange(of: current) { _, newValue in draft = newValue }
            .onSubmit { commit() }
            .onDisappear { commit() }
    }

    private func commit() {
        onCommit(draft)
    }
}
