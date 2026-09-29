import AppKit
import Carbon.HIToolbox

/// A system-wide shortcut that opens the menu.
///
/// Carbon's hot key registration rather than an NSEvent global monitor: the monitor needs
/// Accessibility permission to see key presses in other apps, while a registered hot key is
/// delivered to this app directly and asks for nothing.
@MainActor
final class GlobalHotKey {
    static let openMenuDescription = "⌃⌥M"

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    init(keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void) {
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
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), identifier, GetApplicationEventTarget(), 0, &hotKey)
    }

    /// ⌃⌥M, which no standard macOS shortcut claims.
    static func openMenu(_ action: @escaping @MainActor () -> Void) -> GlobalHotKey {
        GlobalHotKey(keyCode: kVK_ANSI_M, modifiers: controlKey | optionKey, action: action)
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
