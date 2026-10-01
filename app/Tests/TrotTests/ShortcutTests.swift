import AppKit
import Testing
@testable import Trot

@Suite("Shortcuts")
struct ShortcutTests {
    @Test func storedTextRoundTrips() {
        let shortcut = Shortcut(key: "D", keyCode: 2, modifiers: [.option, .shift])
        #expect(shortcut.text == "opt+shift+d@2")
        #expect(Shortcut(text: shortcut.text) == shortcut)
    }

    @Test func parsesEveryModifierInAnyOrder() {
        let parsed = Shortcut(text: "cmd+ctrl+a@0")
        #expect(parsed?.modifiers == [.command, .control])
        #expect(parsed?.keyCode == 0)
        #expect(parsed?.key == "a")
    }

    @Test func theKeyItselfCanBeAnAtSign() {
        let shortcut = Shortcut(key: "@", keyCode: 19, modifiers: [.command])
        #expect(shortcut.text == "cmd+@@19")
        #expect(Shortcut(text: shortcut.text) == shortcut)
    }

    @Test func malformedTextIsRejected() {
        #expect(Shortcut(text: "") == nil)
        #expect(Shortcut(text: "opt+d") == nil)
        #expect(Shortcut(text: "opt+dd@2") == nil)
        #expect(Shortcut(text: "opt+d@x") == nil)
    }

    @Test func displayUsesTheMenuSymbols() {
        #expect(Shortcut(key: "d", keyCode: 2, modifiers: [.control, .option, .shift, .command]).displayString == "⌃⌥⇧⌘D")
        #expect(Shortcut(key: " ", keyCode: 49, modifiers: [.option]).displayString == "⌥Space")
        let f5 = String(UnicodeScalar(NSF5FunctionKey)!)
        #expect(Shortcut(key: f5, keyCode: 96, modifiers: []).displayString == "F5")
    }

    @Test func aBareLetterIsNotUsableButAFunctionKeyIs() {
        #expect(!Shortcut(key: "d", keyCode: 2, modifiers: []).isUsable)
        #expect(!Shortcut(key: "d", keyCode: 2, modifiers: [.shift]).isUsable)
        #expect(Shortcut(key: "d", keyCode: 2, modifiers: [.option]).isUsable)
        let f5 = String(UnicodeScalar(NSF5FunctionKey)!)
        #expect(Shortcut(key: f5, keyCode: 96, modifiers: []).isUsable)
    }

    @Test func equalityIgnoresTheDisplayedCharacter() {
        // The same physical key under two keyboard layouts is one hotkey.
        #expect(Shortcut(key: "d", keyCode: 2, modifiers: [.option]) == Shortcut(key: "в", keyCode: 2, modifiers: [.option]))
    }

    @Test func defaultsFollowBob() {
        #expect(HotKeyAction.translateSelection.defaultShortcut.displayString == "⌥D")
        #expect(HotKeyAction.translateInput.defaultShortcut.displayString == "⌥A")
        #expect(HotKeyAction.translateScreenshot.defaultShortcut.displayString == "⌥S")
    }
}
