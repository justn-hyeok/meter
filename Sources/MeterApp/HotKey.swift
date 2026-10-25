import AppKit
import Carbon.HIToolbox
import MeterCore
import Observation

/// A system-wide shortcut that opens the menu.
///
/// Carbon's hot key registration rather than an NSEvent global monitor: the monitor needs
/// Accessibility permission to see key presses in other apps, while a registered hot key is
/// delivered to this app directly and asks for nothing.
@MainActor
final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    /// Nil when macOS refuses the combination, usually because another app holds it.
    init?(keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void) {
        self.action = action

        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            // Carbon delivers hot key events on the main thread.
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &pressed, context, &handler)

        let identifier = EventHotKeyID(signature: OSType(0x4D54_5252), id: 1) // "MTRR"
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), identifier, GetApplicationEventTarget(), 0, &hotKey)
        guard status == noErr, hotKey != nil else {
            unregister()
            return nil
        }
    }

    /// Stops the shortcut and drops its handler, so replacing it does not leave the old
    /// combination live.
    func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }
}

/// The shortcut the app actually has registered, and the one the settings window edits.
///
/// A registered hot key cannot be changed in place, so applying a new shortcut saves it,
/// tears down the old registration and registers the new one. Everything that shows the
/// shortcut reads it here, so the menu footer and the settings row cannot disagree.
@MainActor
@Observable
final class HotKeyController {
    /// The saved shortcut; nil means the default, ⌃⌥M, and is how a fresh install reads.
    private(set) var setting: HotKeySetting?
    private var hotKey: GlobalHotKey?
    private let settings: MeterSettings
    private let action: @MainActor () -> Void

    init(settings: MeterSettings = MeterSettings(), action: @escaping @MainActor () -> Void) {
        self.settings = settings
        self.action = action
        self.setting = settings.hotKey
    }

    /// The shortcut in force, default included.
    var current: HotKeySetting { setting ?? .standard }

    /// The shortcut as it reads, or nil when it is switched off.
    var display: String? { current.isEnabled ? current.display : nil }

    /// Saves `setting` and registers it in place of the previous one. Nil restores the
    /// default; a switched-off setting registers nothing. Returns false, keeping the previous
    /// shortcut, when macOS will not register the new one: saving it anyway showed a
    /// shortcut as set that did nothing.
    @discardableResult
    func apply(_ setting: HotKeySetting?) -> Bool {
        hotKey?.unregister()
        hotKey = nil
        let resolved = setting ?? .standard
        if resolved.isEnabled {
            guard let registered = GlobalHotKey(keyCode: resolved.keyCode, modifiers: resolved.modifiers, action: action) else {
                register(current)
                return false
            }
            hotKey = registered
        }
        self.setting = setting
        settings.hotKey = setting
        return true
    }

    /// Lets the recorder see the shortcut in force: while it is registered, macOS hands
    /// that key press to the hot key and the recorder never gets it.
    func suspend() {
        hotKey?.unregister()
        hotKey = nil
    }

    func resume() {
        guard hotKey == nil else { return }
        register(current)
    }

    private func register(_ setting: HotKeySetting) {
        guard setting.isEnabled else { return }
        hotKey = GlobalHotKey(keyCode: setting.keyCode, modifiers: setting.modifiers, action: action)
    }
}

/// Opens or closes the menu as if its icon had been clicked.
///
/// `MenuBarExtra` offers no way to do this itself, so the status item's own button is found
/// and clicked. It sits two views down inside the status bar window on macOS 26, not as
/// the window's content view, and the other status bar windows hold only replicas drawn for
/// other displays, which have no button at all. Clicking again closes it, so the shortcut
/// toggles.
@MainActor
enum MenuBarToggle {
    static func toggle() {
        for window in NSApp.windows where window.className.contains("NSStatusBarWindow") {
            if let button = window.contentView.flatMap(firstButton) {
                press(button, in: window)
                return
            }
        }
    }

    /// A status item opens on mouse down, not on its button's action, so `performClick`
    /// does nothing here. Queue the mouse up first so the button's tracking loop finds it
    /// and returns, then deliver the mouse down.
    private static func press(_ button: NSButton, in window: NSWindow) {
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
    }

    private static func firstButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton { return button }
        for subview in view.subviews {
            if let button = firstButton(in: subview) { return button }
        }
        return nil
    }
}
