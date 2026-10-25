import Carbon.HIToolbox
import Foundation
import Testing
@testable import MeterCore

@Test func shortcutsReadInMacModifierOrder() {
    #expect(HotKeyDisplay.string(keyCode: kVK_ANSI_M, modifiers: controlKey | optionKey) == "⌃⌥M")
    #expect(HotKeyDisplay.string(keyCode: kVK_ANSI_K, modifiers: cmdKey | shiftKey) == "⇧⌘K")
    #expect(HotKeyDisplay.string(keyCode: kVK_ANSI_1, modifiers: controlKey | optionKey | shiftKey | cmdKey) == "⌃⌥⇧⌘1")
}

@Test func keysWithoutALetterHaveNames() {
    #expect(HotKeyDisplay.string(keyCode: kVK_F5, modifiers: 0) == "F5")
    #expect(HotKeyDisplay.string(keyCode: kVK_Space, modifiers: 0) == "Space")
    #expect(HotKeyDisplay.string(keyCode: kVK_Delete, modifiers: cmdKey) == "⌘⌫")
    #expect(HotKeyDisplay.string(keyCode: kVK_Return, modifiers: optionKey) == "⌥↩")
    #expect(HotKeyDisplay.string(keyCode: kVK_DownArrow, modifiers: controlKey) == "⌃↓")
}

@Test func shiftAloneCannotMakeAShortcut() {
    #expect(!HotKeyDisplay.hasMenuModifier(shiftKey))
    #expect(!HotKeyDisplay.hasMenuModifier(0))
    #expect(HotKeyDisplay.hasMenuModifier(cmdKey))
    #expect(HotKeyDisplay.hasMenuModifier(controlKey | shiftKey))
    #expect(HotKeyDisplay.hasMenuModifier(optionKey))
}
