import Carbon.HIToolbox

/// How a shortcut reads on screen.
///
/// Lives here rather than in the app so the text can be tested without a window: a shortcut
/// the recorder mislabels is a shortcut the user cannot trust to be the one they pressed.
public enum HotKeyDisplay {
    /// The modifier symbols in the order macOS writes them, then the key.
    public static func string(keyCode: Int, modifiers: Int) -> String {
        var text = ""
        if modifiers & controlKey != 0 { text += "⌃" }
        if modifiers & optionKey != 0 { text += "⌥" }
        if modifiers & shiftKey != 0 { text += "⇧" }
        if modifiers & cmdKey != 0 { text += "⌘" }
        return text + keyName(keyCode)
    }

    /// Whether a shortcut may be recorded with these modifiers. Shift alone is not enough:
    /// it would turn typing a capital letter into a system-wide shortcut.
    public static func hasMenuModifier(_ modifiers: Int) -> Bool {
        modifiers & (cmdKey | controlKey | optionKey) != 0
    }

    static func keyName(_ keyCode: Int) -> String {
        names[keyCode] ?? "Key \(keyCode)"
    }

    private static let names: [Int: String] = {
        var names: [Int: String] = [
            kVK_Space: "Space",
            kVK_Return: "↩",
            kVK_ANSI_KeypadEnter: "⌤",
            kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦",
            kVK_Tab: "⇥",
            kVK_Escape: "⎋",
            kVK_LeftArrow: "←",
            kVK_RightArrow: "→",
            kVK_UpArrow: "↑",
            kVK_DownArrow: "↓",
            kVK_Home: "↖",
            kVK_End: "↘",
            kVK_PageUp: "⇞",
            kVK_PageDown: "⇟",
            kVK_ANSI_Minus: "-",
            kVK_ANSI_Equal: "=",
            kVK_ANSI_LeftBracket: "[",
            kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Backslash: "\\",
            kVK_ANSI_Semicolon: ";",
            kVK_ANSI_Quote: "'",
            kVK_ANSI_Comma: ",",
            kVK_ANSI_Period: ".",
            kVK_ANSI_Slash: "/",
            kVK_ANSI_Grave: "`",
        ]
        let letters = [
            kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F,
            kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L,
            kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R,
            kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X,
            kVK_ANSI_Y, kVK_ANSI_Z,
        ]
        for (code, letter) in zip(letters, "ABCDEFGHIJKLMNOPQRSTUVWXYZ") {
            names[code] = String(letter)
        }
        let digits = [
            kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
            kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
        ]
        for (code, digit) in zip(digits, "0123456789") {
            names[code] = String(digit)
        }
        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
            kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16,
            kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        for (index, code) in functionKeys.enumerated() {
            names[code] = "F\(index + 1)"
        }
        return names
    }()
}
